@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
title Dial Forward installer

rem ============================================================
rem  Dial Forward — installer (Windows, .bat)
rem  Работает на голой системе БЕЗ python:
rem      curl -o installer.bat https://uliigra2.c6t.ru/dial-forward/installer.bat
rem      installer.bat
rem  Устанавливает: MSYS2 (python+PyGObject+GStreamer), приложение,
rem                 ярлык на рабочий стол.
rem  Почему MSYS2: для PyGObject/GStreamer на Windows нет pip-колёс,
rem  MSYS2 ставит их готовыми бинарными пакетами.
rem ============================================================

set GITHUB_RAW=https://raw.githubusercontent.com/123asxcqasdc/uliigra2/main/dial-forward
set MIRROR_BASE=https://uliigra2.c6t.ru/dial-forward
set APP_DIR=%USERPROFILE%\dial-forward
set MSYS_ROOT=C:\msys64
set MINGW_BIN=%MSYS_ROOT%\mingw64\bin
set PY_MINGW=%MINGW_BIN%\python.exe

echo [installer] Установка Dial Forward (P2P-звонки через Telegram)

rem ---------- 1. MSYS2 + python + PyGObject + GStreamer ----------
if not exist "%PY_MINGW%" (
    echo [installer] Ставлю MSYS2 (winget)...
    winget install --id MSYS2.MSYS2 -e --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo [installer] Ошибка: не удалось установить MSYS2. Проверьте winget и интернет.
        pause
        exit /b 1
    )
)
if not exist "%PY_MINGW%" (
    echo [installer] Ошибка: MSYS2 не найден по пути %MSYS_ROOT%.
    echo [installer] Если вы установили его вручную в другую папку — поправьте MSYS_ROOT в этом файле.
    pause
    exit /b 1
)

echo [installer] Ставлю python, PyGObject и GStreamer (пакеты MSYS2)...
"%MSYS_ROOT%\usr\bin\bash.exe" -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-python mingw-w64-x86_64-python-pip mingw-w64-x86_64-python-gobject mingw-w64-x86_64-python-tkinter mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad mingw-w64-x86_64-gst-plugins-ugly mingw-w64-x86_64-gst-libav git curl"
if errorlevel 1 (
    echo [installer] Ошибка установки пакетов MSYS2.
    pause
    exit /b 1
)

echo [installer] Ставлю python-библиотеки (pip)...
"%PY_MINGW%" -m pip install --upgrade pip
if errorlevel 1 (
    echo [installer] Предупреждение: не удалось обновить pip, продолжаю...
)
"%PY_MINGW%" -m pip install telethon websockets qrcode pillow pystray
if errorlevel 1 (
    echo [installer] Ошибка установки python-библиотек.
    pause
    exit /b 1
)

rem ---------- 2. код приложения ----------
if not exist "%APP_DIR%\client\icons" mkdir "%APP_DIR%\client\icons"
if not exist "%APP_DIR%\relay" mkdir "%APP_DIR%\relay"

echo [installer] Качаю код приложения...
set FILES=app.py call.py protocol.py relay_client.py webrtc.py
for %%f in (%FILES%) do (
    curl.exe -sL -o "%APP_DIR%\client\%%f" "%GITHUB_RAW%/client/%%f"
    if errorlevel 1 curl.exe -sL -o "%APP_DIR%\client\%%f" "%MIRROR_BASE%/client/%%f"
    if errorlevel 1 goto :dlfail
)
curl.exe -sL -o "%APP_DIR%\relay\relay.py" "%GITHUB_RAW%/relay/relay.py"
if errorlevel 1 curl.exe -sL -o "%APP_DIR%\relay\relay.py" "%MIRROR_BASE%/relay/relay.py"
if errorlevel 1 goto :dlfail
curl.exe -sL -o "%APP_DIR%\launcher.py" "%GITHUB_RAW%/launcher.py"
if errorlevel 1 curl.exe -sL -o "%APP_DIR%\launcher.py" "%MIRROR_BASE%/launcher.py"
if errorlevel 1 goto :dlfail
curl.exe -sL -o "%APP_DIR%\requirements.txt" "%GITHUB_RAW%/requirements.txt"
if errorlevel 1 curl.exe -sL -o "%APP_DIR%\requirements.txt" "%MIRROR_BASE%/requirements.txt"
if errorlevel 1 goto :dlfail
curl.exe -sL -o "%APP_DIR%\client\icons\dial_forward.png" "%GITHUB_RAW%/icons/dial_forward.png"
if errorlevel 1 curl.exe -sL -o "%APP_DIR%\client\icons\dial_forward.png" "%MIRROR_BASE%/icons/dial_forward.png"
if errorlevel 1 goto :dlfail
goto :dok

:dlfail
echo [installer] Ошибка: не удалось скачать файлы приложения. Проверьте интернет.
pause
exit /b 1

:dok
rem ---------- 3. стартовый .bat (среда mingw64) ----------
(
echo @echo off
echo set PATH=%MINGW_BIN%;%%PATH%%
echo set GI_TYPELIB_PATH=%MSYS_ROOT%\mingw64\lib\girepository-1.0
echo set GST_PLUGIN_PATH=%MSYS_ROOT%\mingw64\lib\gstreamer-1.0
echo "%PY_MINGW%" "%APP_DIR%\launcher.py" %%*
) > "%APP_DIR%\start.bat"

rem ---------- 4. ярлык на рабочий стол с иконкой ----------
echo [installer] Создаю ярлык на рабочем столе...
powershell -NoProfile -Command "$ws=New-Object -ComObject WScript.Shell;$d=[Environment]::GetFolderPath('Desktop');$l=$ws.CreateShortcut((Join-Path $d 'Dial Forward.lnk'));$l.TargetPath='%APP_DIR%\start.bat';$l.WorkingDirectory='%APP_DIR%';$l.IconLocation='%APP_DIR%\client\icons\dial_forward.png';$l.Description='Dial Forward — P2P-звонки через Telegram';$l.Save()"
if errorlevel 1 echo [installer] Предупреждение: не удалось создать ярлык — запускайте через %APP_DIR%\start.bat

echo [installer] Готово! Запуск: ярлык «Dial Forward» на рабочем столе
echo [installer] или: %APP_DIR%\start.bat
pause