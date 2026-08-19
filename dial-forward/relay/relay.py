#!/usr/bin/env python3
"""TGRTC relay — Telegram MTProto сигналинг для P2P-звонков.

- берёт api_id/api_hash из установленного Telegram Desktop (tdata/config или бинарник)
- логинится как пользователь (MTProto, Telethon)
- по команде создаёт приватную группу и обменивается в ней сигналингом
- локальный WebSocket API (127.0.0.1:4545) для GUI-клиента
"""
import asyncio
import json
import logging
import os
import re
import time

import websockets
from telethon import TelegramClient, functions
from telethon.errors import (PhoneCodeInvalidError, SendCodeUnavailableError,
                             SessionPasswordNeededError)
from telethon.events import NewMessage
from telethon.network.connection.tcpobfuscated import ConnectionTcpObfuscated
from telethon.tl.types import Message as TLMessage

log = logging.getLogger("relay")

OFFICIAL_API_ID = 2040
OFFICIAL_API_HASH = "b18441a1ff607e10a989891a5462e627"
WS_ADDR = ("127.0.0.1", 4545)


# ---------- ключи (без Telegram Desktop) ----------

def extract_keys():
    """Официальные ключи MTProto захардкожены; опционально перекрываются
    конфигом установленного Telegram Desktop (tdata/config)."""
    home = os.path.expanduser("~")
    xdg = os.environ.get("XDG_DATA_HOME", "")
    tdata = []
    if xdg:
        tdata.append(os.path.join(xdg, "TelegramDesktop", "tdata"))
    tdata += [
        os.path.join(home, ".local", "share", "TelegramDesktop", "tdata"),
        os.path.join(home, ".var", "app", "org.telegram.desktop", "data", "TelegramDesktop", "tdata"),
    ]
    for d in tdata:
        r = read_config_override(d)
        if r:
            return {"api_id": r[0], "api_hash": r[1], "tdata": d, "source": "tdata/config"}
    return {"api_id": OFFICIAL_API_ID, "api_hash": OFFICIAL_API_HASH, "source": "builtin"}


def read_config_override(dir_path):
    path = os.path.join(dir_path, "config")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    try:
        data = json.loads(text)
        api_id = int(data.get("api_id", 0))
        api_hash = data.get("api_hash", "")
        if api_id and api_hash:
            return api_id, api_hash
    except (ValueError, TypeError):
        pass
    m_id = re.search(r"api_id\s*[=:]?\s*(\d+)", text)
    m_hash = re.search(r"api_hash\s*[=:]?\s*([0-9a-fA-F]{32})", text)
    if m_id and m_hash:
        return int(m_id.group(1)), m_hash.group(1)
    return None


# ---------- DC probing ----------

DC_CANDIDATES = [
    (2, "2001:67c:4e8:f002::a", 443),
    (2, "2001:67c:4e8:f006::a", 443),
    (2, "149.154.167.51", 443),
    (2, "149.154.167.51", 80),
    (2, "149.154.167.41", 80),
    (2, "2001:b28:f23f:f005::a", 443),
    (1, "2001:67c:4e8:d001::a", 443),
    (1, "2001:b28:f23d:f001::a", 443),
    (1, "149.154.175.53", 443),
    (5, "91.108.56.130", 443),
]


async def probe_dc(fixed_dc=None):
    cands = [c for c in DC_CANDIDATES if fixed_dc is None or c[0] == fixed_dc]
    if not cands:
        cands = DC_CANDIDATES
    for dc_id, ip, port in cands:
        try:
            _, writer = await asyncio.wait_for(
                asyncio.open_connection(ip, port), timeout=12)
            writer.close()
            log.info("dc probe ok: [%s]%s:%s", dc_id, ip, port)
            return dc_id, ip, port
        except (OSError, asyncio.TimeoutError):
            log.info("dc probe fail: [%s]%s:%s", dc_id, ip, port)
    return None


# ---------- relay ----------

class Relay:
    def __init__(self, keys):
        self.keys = keys
        self.client = None
        self.clients = set()
        self.self_id = None
        self.phone = None
        self.code_hash = None
        self.calls = {}
        self.seen_ids = {}

    async def start(self):
        asyncio.create_task(self._connect())

    async def _connect(self):
        while True:
            fixed_dc = None
            if self.client is not None and self.client.session.auth_key:
                fixed_dc = self.client.session.dc_id
            dc = await probe_dc(fixed_dc)
            if dc is None:
                log.warning("нет доступного DC — повторный зонд через 10s")
                await asyncio.sleep(10)
                continue
            dc_id, ip, port = dc
            ipv6 = ":" in ip
            if self.client is None:
                self.client = TelegramClient(
                    "tgrtc.session", self.keys["api_id"], self.keys["api_hash"],
                    connection=ConnectionTcpObfuscated,
                    use_ipv6=ipv6, connection_retries=8, retry_delay=4)
                @self.client.on(NewMessage)
                async def handler(event: NewMessage.Event):
                    await self.on_new_message(event)
            try:
                self.client.session.set_dc(dc_id, ip, port)
                await self.client.connect()
                break
            except Exception as e:
                log.warning("telegram connect failed: %s — retry in 10s", e)
                name = type(e).__name__
                if (self.self_id is None and self.client is not None
                        and "AuthKeyNotFound" in name):
                    await self._reset_session()
                await asyncio.sleep(10)
        try:
            if await self.client.is_user_authorized():
                await self.after_login()
            else:
                await self.broadcast({"event": "need_login"})
        except Exception as e:
            log.exception("auth check failed")
            await self.broadcast({"event": "fatal", "error": str(e)})

    async def _reset_session(self):
        """Удаляет битую (оборванную на рукопожатии) сессию, пока вход не завершён."""
        try:
            await self.client.disconnect()
        except Exception:
            pass
        self.client = None
        for f in ("tgrtc.session", "tgrtc.session-journal",
                  "tgrtc.session-shm", "tgrtc.session-wal"):
            try:
                os.remove(f)
            except OSError:
                pass
        log.info("session reset (broken transport key)")

    async def after_login(self):
        me = await self._retry(self.client.get_me)
        self.self_id = me.id
        log.info("logged in as %s (%s)", me.first_name, me.id)
        await self.broadcast({"event": "logged_in", "self_id": me.id, "first_name": me.first_name})

    async def on_new_message(self, event):
        msg = event.message
        if not isinstance(msg, TLMessage) or not msg.message:
            return
        now = time.monotonic()
        self.seen_ids = {k: v for k, v in self.seen_ids.items() if now - v < 300}
        if msg.id in self.seen_ids:
            return
        self.seen_ids[msg.id] = now
        pid = getattr(msg, "peer_id", None)
        chat_id = (getattr(pid, "chat_id", None) or getattr(pid, "channel_id", None)
                   or getattr(pid, "user_id", None))
        from_id = getattr(msg.from_id, "user_id", None) if msg.from_id else None
        await self.broadcast({
            "event": "message",
            "chat_id": chat_id,
            "from_id": from_id,
            "msg_id": msg.id,
            "text": msg.message,
        })

    async def broadcast(self, data: dict):
        if not self.clients:
            return
        text = json.dumps(data)
        dead = []
        for ws in list(self.clients):
            try:
                await ws.send(text)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.clients.discard(ws)

    # ---- команды ----

    async def status(self):
        return {
            "api_id": self.keys["api_id"],
            "source": self.keys.get("source"),
            "self_id": self.self_id,
            "authorized": self.self_id is not None,
            "connected": bool(self.client and self.client.is_connected()),
        }

    async def login_phone(self, phone):
        self.phone = phone
        try:
            sent = await self._retry(lambda: self.client.send_code_request(phone))
        except SendCodeUnavailableError:
            return {"error": "код уже отправлен ранее — проверьте SMS/Telegram. Повторную отправку ограничили, подождите пару минут."}
        self.code_hash = sent.phone_code_hash
        return {"code_hash": self.code_hash}

    async def login_qr(self):
        if self.client is None or not self.client.is_connected():
            return {"error": "подключение к Telegram ещё идёт, попробуйте через пару секунд"}
        qr = await self.client.qr_login()
        self.qr = qr
        asyncio.create_task(self._wait_qr(qr))
        return {"url": qr.url}

    async def _wait_qr(self, qr):
        try:
            await qr.wait(timeout=90)
            await self.after_login()
        except SessionPasswordNeededError:
            self.qr_password = True
            await self.broadcast({"event": "qr_password_needed"})
        except asyncio.TimeoutError:
            if self.self_id is None:
                await self.broadcast({"event": "qr_expired"})
        except Exception as e:
            if self.self_id is None:
                log.exception("qr login failed")
                await self.broadcast({"event": "qr_error", "error": str(e)})

    async def _retry(self, coro_factory, retries=3):
        last = None
        for _ in range(retries):
            try:
                return await coro_factory()
            except (ConnectionError, TimeoutError, OSError,
                    ValueError, RuntimeError) as e:
                last = e
                log.warning("transport error, retry: %s", e)
                await asyncio.sleep(3)
        raise last

    async def login_code(self, code, code_hash):
        try:
            await self._retry(lambda: self.client.sign_in(
                self.phone, code, phone_code_hash=code_hash))
        except SessionPasswordNeededError:
            return {"need_password": True}
        except PhoneCodeInvalidError:
            return {"error": "неверный код"}
        await self.after_login()
        return {}

    async def login_password(self, password):
        await self._retry(lambda: self.client.sign_in(self.phone, password=password))
        await self.after_login()
        return {}

    async def logout(self):
        await self.client.log_out()
        self.self_id = None
        return {}

    async def resolve(self, username):
        username = username.lstrip("@").strip()
        entity = await self.client.get_entity(username)
        return {"user_id": entity.id, "username": getattr(entity, "username", ""), "first_name": getattr(entity, "first_name", "")}

    async def call(self, username, title, user_id=None):
        if username:
            username = username.lstrip("@").strip()
            user = await self.client.get_entity(username)
        else:
            user = await self.client.get_entity(int(user_id))
        if user.id in self.calls:
            chat_id = self.calls[user.id]
            try:
                members = await self.client.get_participants(chat_id)
                if not any(m.id == user.id for m in members):
                    await self.client(functions.messages.AddChatUserRequest(
                        chat_id=abs(int(chat_id)), user_id=user.id, fwd_limit=50))
            except Exception as err:
                log.warning("повторное добавление участника: %s", err)
            return {"chat_id": chat_id, "user_id": user.id}
        if not title:
            title = f"Call {getattr(user, 'first_name', username)}"
        async for d in self.client.iter_dialogs():
            e = d.entity
            if getattr(e, "title", "") == title:
                members = await self.client.get_participants(e.id)
                if any(m.id == user.id for m in members):
                    self.calls[user.id] = e.id
                    return {"chat_id": e.id, "user_id": user.id, "reused": True}
                if len(members) == 1:
                    try:
                        await self.client(functions.messages.AddChatUserRequest(
                            chat_id=abs(int(e.id)), user_id=user.id, fwd_limit=50))
                        self.calls[user.id] = e.id
                        return {"chat_id": e.id, "user_id": user.id, "reused": True,
                                "invite_sent": True}
                    except Exception as err:
                        log.warning("AddChatUser в существующей группе: %s", err)
        updates = await self.client(functions.messages.CreateChatRequest(
            users=[user],
            title=title,
        ))
        chat_id = None
        updates_obj = getattr(updates, "updates", None) or updates
        for u in getattr(updates_obj, "updates", []):
            m = getattr(u, "message", None)
            if m is not None and m.peer_id is not None:
                chat_id = getattr(m.peer_id, "chat_id", None)
                if chat_id:
                    break
        if chat_id is None:
            async for d in self.client.iter_dialogs():
                if d.title == title:
                    chat_id = d.id
                    break
        if chat_id is None:
            return {"error": "группа создана, но id не найден"}
        try:
            members = await self.client.get_participants(chat_id)
            if not any(m.id == user.id for m in members):
                await self.client(functions.messages.AddChatUserRequest(
                    chat_id=chat_id, user_id=user.id, fwd_limit=50))
        except Exception as e:
            log.warning("проверка/добавление участника: %s", e)
        self.calls[user.id] = chat_id
        return {"chat_id": chat_id, "user_id": user.id}

    async def call_group(self, usernames, title):
        users = []
        for u in usernames:
            u = u.lstrip("@").strip()
            entity = await self.client.get_entity(u)
            users.append(entity)
        if not title:
            title = "Call " + " & ".join(getattr(u, "first_name", u.id)
                                          for u in users[:3])
        title = title[:64]
        updates = await self.client(functions.messages.CreateChatRequest(
            users=users, title=title))
        chat_id = None
        updates_obj = getattr(updates, "updates", None) or updates
        for u in getattr(updates_obj, "updates", []):
            m = getattr(u, "message", None)
            if m is not None and m.peer_id is not None:
                chat_id = getattr(m.peer_id, "chat_id", None)
                if chat_id:
                    break
        if chat_id is None:
            async for d in self.client.iter_dialogs():
                if d.title == title:
                    chat_id = d.id
                    break
        if chat_id is None:
            return {"error": "группа создана, но id не найден"}
        return {"chat_id": chat_id, "user_id": [u.id for u in users]}

    async def invite(self, chat_id, username):
        username = username.lstrip("@").strip()
        user = await self.client.get_entity(username)
        await self.client(functions.messages.AddChatUserRequest(
            chat_id=abs(int(chat_id)), user_id=user.id, fwd_limit=50))
        return {"user_id": user.id}

    async def chat_info(self, chat_id):
        users = await self.client.get_participants(chat_id)
        return {"members": [{
            "user_id": u.id,
            "username": getattr(u, "username", ""),
            "first_name": getattr(u, "first_name", ""),
        } for u in users]}

    async def leave(self, chat_id):
        chat_id = abs(int(chat_id))
        try:
            members = await self.client.get_participants(chat_id)
            for m in members:
                if m.id == self.self_id:
                    continue
                try:
                    await self.client(functions.messages.DeleteChatUserRequest(
                        chat_id=chat_id, user_id=m.id))
                    log.info("участник %s исключён", m.id)
                except Exception as err:
                    log.warning("исключение участника %s: %s", m.id, err)
        except Exception as err:
            log.warning("список участников: %s", err)
        try:
            await self.client(functions.messages.DeleteChatRequest(chat_id=chat_id))
        except Exception as err:
            log.warning("DeleteChatRequest: %s", err)
        self.calls = {k: v for k, v in self.calls.items() if v != int(chat_id)}
        return {}

    async def dialogs(self):
        out = []
        async for d in self.client.iter_dialogs():
            e = d.entity
            if hasattr(e, "first_name"):
                out.append({
                    "type": "user",
                    "id": e.id,
                    "title": d.title,
                    "username": getattr(e, "username", ""),
                    "first_name": getattr(e, "first_name", ""),
                })
            else:
                out.append({
                    "type": "chat",
                    "id": d.id,
                    "title": getattr(e, "title", ""),
                    "participants": getattr(e, "participants_count", None),
                })
        return {"dialogs": out}

    async def send_file(self, chat_id, path):
        if not os.path.isfile(path):
            return {"error": f"файл не найден: {path}"}
        name = os.path.basename(path)

        def progress_cb(current, total):
            asyncio.ensure_future(self.broadcast({
                "event": "progress",
                "chat_id": chat_id,
                "name": name,
                "current": current,
                "total": total,
            }))

        await self.client.send_file(chat_id, path, progress_callback=progress_cb)
        return {"name": name}

    async def check_group(self, user_ids):
        """Можно ли добавить пользователя в группу: нужен username или контакт."""
        result = {}
        for uid in user_ids:
            try:
                entity = await self.client.get_entity(int(uid))
                result[uid] = bool(getattr(entity, "username", "")) or bool(
                    getattr(entity, "contact", False))
            except Exception as e:
                log.warning("check_group %s: %s", uid, e)
                result[uid] = False
        return {"result": result}

    async def send(self, chat_id, text):
        if not text:
            return {"error": "пустое сообщение"}
        sent = await self.client.send_message(chat_id, text)
        # исходящие не порождают событий — раздаём их клиентам сами,
        # чтобы клиенты одного relay могли сигналить друг другу
        await self.broadcast({
            "event": "message",
            "chat_id": chat_id,
            "from_id": self.self_id,
            "msg_id": getattr(sent, "id", 0),
            "text": text,
        })
        return {}

    async def handle_cmd(self, cmd: str, data: dict) -> dict:
        handlers = {
            "ping": lambda: {},
            "status": self.status,
            "login_phone": lambda: self.login_phone(data.get("phone", "")),
            "login_qr": self.login_qr,
            "login_code": lambda: self.login_code(data.get("code", ""), data.get("code_hash", "")),
            "login_password": lambda: self.login_password(data.get("password", "")),
            "logout": self.logout,
            "resolve": lambda: self.resolve(data.get("username", "")),
            "call": lambda: self.call(data.get("username", ""), data.get("title", ""),
                                      data.get("user_id")),
            "call_group": lambda: self.call_group(data.get("usernames", []), data.get("title", "")),
            "invite": lambda: self.invite(data.get("chat_id", 0), data.get("username", "")),
            "chat_info": lambda: self.chat_info(data.get("chat_id", 0)),
            "dialogs": self.dialogs,
            "leave": lambda: self.leave(data.get("chat_id", 0)),
            "send": lambda: self.send(data.get("chat_id", 0), data.get("text", "")),
            "send_file": lambda: self.send_file(data.get("chat_id", 0), data.get("path", "")),
            "check_group": lambda: self.check_group(data.get("user_ids", [])),
        }
        fn = handlers.get(cmd)
        if fn is None:
            return {"error": f"unknown command: {cmd}"}
        try:
            result = fn()
            if asyncio.iscoroutine(result):
                result = await result
        except Exception as e:
            log.exception("command %s failed", cmd)
            return {"error": str(e)}
        result = result or {}
        result.setdefault("ok", True)
        return result


async def ws_handler(relay: Relay, ws):
    relay.clients.add(ws)
    log.info("gui connected")
    try:
        async for raw in ws:
            try:
                req = json.loads(raw)
            except json.JSONDecodeError:
                await ws.send(json.dumps({"ok": False, "error": "bad json"}))
                continue
            cmd = req.get("cmd", "")
            log.info("cmd: %s", cmd)
            resp = await relay.handle_cmd(cmd, req)
            await ws.send(json.dumps(resp))
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        relay.clients.discard(ws)
        log.info("gui disconnected")


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    keys = extract_keys()
    log.info("keys: api_id=%s source=%s", keys["api_id"], keys["source"])

    relay = Relay(keys)
    await relay.start()

    async with websockets.serve(lambda ws: ws_handler(relay, ws), WS_ADDR[0], WS_ADDR[1],
                                max_size=8 << 20):
        log.info("relay listening on ws://%s:%d", *WS_ADDR)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
