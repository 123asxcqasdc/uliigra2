# ============================================================
#  Dial Forward — installer (Windows, PowerShell)
#  Работает на голой системе БЕЗ python:
#      curl -o installer.ps1 https://uliigra2.c6t.ru/dial-forward/installer.ps1
#      powershell -ExecutionPolicy Bypass -File installer.ps1
#  Устанавливает: python, gstreamer, приложение, ярлык на рабочий стол.
# ============================================================
$ErrorActionPreference = "Stop"

$GITHUB_RAW = "https://raw.githubusercontent.com/123asxcqasdc/uliigra2/main/dial-forward"
$MIRROR_BASE = "https://uliigra2.c6t.ru/dial-forward"
$GST_VERSION = "1.24.11"
$APP_DIR = Join-Path $env:USERPROFILE "dial-forward"

function Say($m) { Write-Host "[installer] $m" -ForegroundColor Green }

# ---------- 1. python ----------
Say "Устанавливаю Python..."
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    winget install --id Python.Python.3.13 -e `
        --accept-source-agreements --accept-package-agreements | Out-Null
    # обновить PATH для текущей сессии
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}
$PY = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $PY) { $PY = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe" }
if (-not (Test-Path $PY)) { throw "Python не найден — установите вручную https://www.python.org/downloads/" }

# ---------- 2. gstreamer (runtime) ----------
Say "Устанавливаю GStreamer $GST_VERSION ..."
$gstMsi = Join-Path $env:TEMP "gstreamer-runtime.msi"
try {
    Invoke-WebRequest "https://gstreamer.freedesktop.org/data/pkg/windows/$GST_VERSION/gstreamer-1.0-runtime-x86_64-$GST_VERSION.msi" `
        -OutFile $gstMsi -UseBasicParsing
    Start-Process msiexec -ArgumentList "/i `"$gstMsi`" /qn" -Wait
    $env:GST_PLUGIN_PATH = "C:\gstreamer\1.0\x86_64\lib\gstreamer-1.0"
    $env:Path += ";C:\gstreamer\1.0\x86_64\bin"
} catch {
    Say "GStreamer MSI не скачался — установите вручную: https://gstreamer.freedesktop.org/download/"
}

# ---------- 3. код приложения ----------
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

# ---------- 4. venv + библиотеки ----------
Say "Создаю виртуальное окружение..."
& $PY -m venv "$APP_DIR\.venv"
$VenvPy = Join-Path $APP_DIR ".venv\Scripts\python.exe"
& $VenvPy -m pip install --upgrade pip | Out-Null
Say "Устанавливаю python-библиотеки..."
& $VenvPy -m pip install -r (Join-Path $APP_DIR "requirements.txt")

# ---------- 5. ярлык на рабочий стол ----------
Say "Создаю ярлык на рабочем столе..."
$desktop = [Environment]::GetFolderPath("Desktop")
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desktop "Dial Forward.lnk"))
$lnk.TargetPath = Join-Path $APP_DIR ".venv\Scripts\pythonw.exe"
$lnk.Arguments = "`"$(Join-Path $APP_DIR 'launcher.py')`""
$lnk.WorkingDirectory = $APP_DIR
$lnk.Description = "Dial Forward — P2P звонки через Telegram"
$lnk.Save()

Say "Готово! Запуск: ярлык «Dial Forward» на рабочем столе"
Say "или: $VenvPy $APP_DIR\launcher.py"
