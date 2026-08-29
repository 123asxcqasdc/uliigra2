import base64
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ["GITHUB_TOKEN"]
repo = os.environ["GITHUB_REPOSITORY"]
path = "dial-forward/DialForward.msi"
ver = open("VERSION").read().strip()
data = open("DialForward.msi", "rb").read()


def api(url, method="GET", body=None):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/{url}",
        data=json.dumps(body).encode() if body else None,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"status": e.code, "msg": e.read().decode()}


existing = api(f"contents/{path}")
body = {
    "message": f"ci: build DialForward.msi {ver}",
    "content": base64.b64encode(data).decode(),
}
if "sha" in existing:
    body["sha"] = existing["sha"]
res = api(f"contents/{path}", "PUT", body)
if "content" not in res and res.get("status") not in (200, 201):
    print("API push failed:", res, file=sys.stderr)
    sys.exit(1)
print("pushed MSI via API")
