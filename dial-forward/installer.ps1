# ============================================================
#  Dial Forward — installer (Windows, PowerShell)
#  Работает на голой системе БЕЗ python:
#      curl -o installer.ps1 https://uliigra2.c6t.ru/dial-forward/installer.ps1
#      powershell -ExecutionPolicy Bypass -File installer.ps1
#  Устанавливает: MSYS2 (python+PyGObject+GStreamer), приложение,
#                 ярлык на рабочий стол.
#  Почему MSYS2: для PyGObject/GStreamer на Windows нет pip-колёс,
#  MSYS2 ставит их готовыми бинарными пакетами.
# ============================================================
$ErrorActionPreference = "Stop"

$GITHUB_RAW = "https://raw.githubusercontent.com/123asxcqasdc/uliigra2/main/dial-forward"
$MIRROR_BASE = "https://uliigra2.c6t.ru/dial-forward"
$APP_DIR = Join-Path $env:USERPROFILE "dial-forward"
$MSYS_ROOT = "C:\msys64"
$MINGW_BIN = "$MSYS_ROOT\mingw64\bin"
$PY_MINGW = "$MINGW_BIN\python.exe"

function Say($m) { Write-Host "[installer] $m" -ForegroundColor Green }

# ---------- 1. MSYS2 + python + PyGObject + GStreamer ----------
if (-not (Test-Path $PY_MINGW)) {
    Say "Устанавливаю MSYS2..."
    winget install --id MSYS2.MSYS2 -e `
        --accept-source-agreements --accept-package-agreements
    # обновить PATH текущей сессии
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}
if (-not (Test-Path $PY_MINGW)) { throw "MSYS2 не найден по пути $MSYS_ROOT" }

Say "Ставлю python, PyGObject и GStreamer (пакеты MSYS2)..."
$pac = "$MSYS_ROOT\usr\bin\bash.exe"
& $pac -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-python mingw-w64-x86_64-python-pip mingw-w64-x86_64-python-gobject mingw-w64-x86_64-python-tkinter mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad mingw-w64-x86_64-gst-plugins-ugly mingw-w64-x86_64-gst-libav git curl"

Say "Устанавливаю python-библиотеки (pip)..."
& $PY_MINGW -m pip install --upgrade pip
& $PY_MINGW -m pip install telethon websockets qrcode pillow

# ---------- 2. код приложения ----------
function Fetch-File($remote, $local) {
    $srcs = @("$GITHUB_RAW/$remote", "$MIRROR_BASE/$remote")
    foreach ($src in $srcs) {
        try {
            Invoke-WebRequest $src -OutFile $local -UseBasicParsing
            return
        } catch { }
    }
    throw "Не удалось скачать $remote"
}

Say "Качаю код приложения..."
New-Item -ItemType Directory -Force -Path (Join-Path $APP_DIR "client"), (Join-Path $APP_DIR "relay") | Out-Null
foreach ($f in @("app.py", "call.py", "protocol.py", "relay_client.py", "webrtc.py")) {
    Fetch-File "client/$f" (Join-Path $APP_DIR "client\$f")
}
Fetch-File "relay/relay.py" (Join-Path $APP_DIR "relay\relay.py")
Fetch-File "launcher.py" (Join-Path $APP_DIR "launcher.py")
Fetch-File "requirements.txt" (Join-Path $APP_DIR "requirements.txt")

# ---------- 3. стартовый .bat (среда mingw64) ----------
$bat = Join-Path $APP_DIR "start.bat"
@"
@echo off
set PATH=$MINGW_BIN;%PATH%
set GI_TYPELIB_PATH=$MSYS_ROOT\mingw64\lib\girepository-1.0
set GST_PLUGIN_PATH=$MSYS_ROOT\mingw64\lib\gstreamer-1.0
"$PY_MINGW" "$APP_DIR\launcher.py" %*
"@ | Out-File -Encoding ascii $bat

# ---------- 4. ярлык на рабочий стол ----------
Say "Создаю ярлык на рабочем столе..."
$desktop = [Environment]::GetFolderPath("Desktop")
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desktop "Dial Forward.lnk"))
$lnk.TargetPath = $bat
$lnk.WorkingDirectory = $APP_DIR
$lnk.Description = "Dial Forward — P2P звонки через Telegram"
$lnk.Save()

Say "Готово! Запуск: ярлык «Dial Forward» на рабочем столе"
Say "или: $APP_DIR\start.bat"
