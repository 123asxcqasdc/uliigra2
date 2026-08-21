@echo off
setlocal EnableDelayedExpansion
title Dial Forward installer

rem ============================================================
rem  Dial Forward - installer (Windows, .bat)
rem  Works on a bare system WITHOUT python:
rem      curl -o installer.bat https://uliigra2.c6t.ru/dial-forward/installer.bat
rem      installer.bat
rem  Installs: MSYS2 (python+PyGObject+GStreamer), app files,
rem            desktop shortcut.
rem  Why MSYS2: there are no pip wheels for PyGObject/GStreamer on
rem  Windows; MSYS2 ships them as ready binary packages.
rem  No nested parens - compatible with cmd and wine.
rem ============================================================

set GITHUB_RAW=https://raw.githubusercontent.com/123asxcqasdc/uliigra2/main/dial-forward
set MIRROR_BASE=https://uliigra2.c6t.ru/dial-forward
set APP_DIR=%USERPROFILE%\dial-forward
set MSYS_ROOT=C:\msys64
set MSYS_BASH=%MSYS_ROOT%\usr\bin\bash.exe
set MINGW_BIN=%MSYS_ROOT%\mingw64\bin
set PY_MINGW=%MINGW_BIN%\python.exe

echo [installer] Installing Dial Forward (P2P calls over Telegram)

rem ---------- 1. MSYS2 + python + PyGObject + GStreamer ----------
if exist "%MSYS_BASH%" goto have_msys

echo [installer] Installing MSYS2 (winget)...
winget install --id MSYS2.MSYS2 -e --accept-source-agreements --accept-package-agreements
if exist "%MSYS_BASH%" goto have_msys

echo [installer] ERROR: MSYS2 is not installed (no winget or install failed).
echo [installer] Install MSYS2 manually from https://www.msys2.org into %MSYS_ROOT%
echo [installer] and run installer.bat again.
pause
exit /b 1

:have_msys
echo [installer] Installing python and GStreamer (MSYS2 packages)...
set PACMAN_PKGS=mingw-w64-x86_64-python mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad mingw-w64-x86_64-gst-plugins-ugly mingw-w64-x86_64-gst-libav git curl
set /a TRY=0
:pac_try
set /a TRY+=1
"%MSYS_BASH%" -lc "pacman -Sy --noconfirm --needed %PACMAN_PKGS%"
if not errorlevel 1 goto msys_ok
if %TRY% geq 3 goto msys_fail
echo [installer] pacman failed (attempt %TRY%/3), retrying...
goto pac_try
:msys_fail
echo [installer] WARNING: pacman failed after 3 attempts - continuing.
echo [installer] Downloaded packages are cached, run installer.bat again to resume.
:msys_ok

rem extra packages one-by-one: a missing target must not block the rest
for %%p in (mingw-w64-x86_64-python-pip mingw-w64-x86_64-python-gobject mingw-w64-x86_64-tk mingw-w64-x86_64-python-pillow) do "%MSYS_BASH%" -lc "pacman -S --noconfirm --needed %%p"

if exist "%PY_MINGW%" goto venv_step
echo [installer] ERROR: %PY_MINGW% not found after pacman.
echo [installer] Try running: %MSYS_BASH% -lc "pacman -Sy mingw-w64-x86_64-python"
pause
exit /b 1

:venv_step
rem MSYS2 python is externally managed (PEP 668). Try a venv first;
rem mingw-python may lay it out as Scripts\ or bin\ - check both.
rem Pillow/PyGObject come from MSYS2 packages, so share site-packages.
echo [installer] Creating virtual environment...
"%PY_MINGW%" -m venv --system-site-packages "%APP_DIR%\.venv" >nul 2>&1
if exist "%APP_DIR%\.venv\Scripts\python.exe" goto venv_scripts
if exist "%APP_DIR%\.venv\bin\python.exe" goto venv_bin

rem venv unusable - fall back to system python with PEP 668 override
echo [installer] WARNING: venv is not usable, using MSYS2 python directly.
set VPY=%PY_MINGW%
set PIP_FLAGS=--break-system-packages
goto have_vpy

:venv_scripts
set VPY=%APP_DIR%\.venv\Scripts\python.exe
set PIP_FLAGS=
goto have_vpy

:venv_bin
set VPY=%APP_DIR%\.venv\bin\python.exe
set PIP_FLAGS=

:have_vpy
echo [installer] Installing python libraries (pip)...
"%VPY%" -m pip install --upgrade pip %PIP_FLAGS%
"%VPY%" -m pip install %PIP_FLAGS% telethon websockets qrcode pystray
if not errorlevel 1 goto pip_ok
echo [installer] ERROR: python libraries install failed. Check internet and run installer.bat again.
pause
exit /b 1
:pip_ok

rem ---------- 2. app code ----------
if not exist "%APP_DIR%\client\icons" mkdir "%APP_DIR%\client\icons"
if not exist "%APP_DIR%\relay" mkdir "%APP_DIR%\relay"

echo [installer] Downloading app code...
set FILES=app.py call.py protocol.py relay_client.py webrtc.py
for %%f in (%FILES%) do call :fetch "client/%%f" "%APP_DIR%\client\%%f"
call :fetch "relay/relay.py" "%APP_DIR%\relay\relay.py"
call :fetch "launcher.py" "%APP_DIR%\launcher.py"
call :fetch "requirements.txt" "%APP_DIR%\requirements.txt"
call :fetch "icons/dial_forward.png" "%APP_DIR%\client\icons\dial_forward.png"
if not errorlevel 1 goto dl_ok

:dlfail
echo [installer] ERROR: could not download app files. Check internet.
pause
exit /b 1

:dl_ok

rem ---------- 3. launcher .bat (mingw64 environment) ----------
echo @echo off> "%APP_DIR%\start.bat"
>>"%APP_DIR%\start.bat" echo set PATH=%MINGW_BIN%;%%PATH%%
>>"%APP_DIR%\start.bat" echo set GI_TYPELIB_PATH=%MSYS_ROOT%\mingw64\lib\girepository-1.0
>>"%APP_DIR%\start.bat" echo set GST_PLUGIN_PATH=%MSYS_ROOT%\mingw64\lib\gstreamer-1.0
>>"%APP_DIR%\start.bat" echo "%VPY%" "%APP_DIR%\launcher.py" %%*

rem ---------- 4. desktop shortcut with icon ----------
echo [installer] Creating desktop shortcut...
powershell -NoProfile -Command "$ws=New-Object -ComObject WScript.Shell;$d=[Environment]::GetFolderPath('Desktop');$l=$ws.CreateShortcut((Join-Path $d 'Dial Forward.lnk'));$l.TargetPath='%APP_DIR%\start.bat';$l.WorkingDirectory='%APP_DIR%';$l.IconLocation='%APP_DIR%\client\icons\dial_forward.png';$l.Description='Dial Forward - P2P calls over Telegram';$l.Save()"
if not errorlevel 1 goto lnk_ok
echo [installer] WARNING: shortcut was not created - run %APP_DIR%\start.bat instead.
:lnk_ok

echo [installer] Done! Run: 'Dial Forward' shortcut on your desktop
echo [installer] or: %APP_DIR%\start.bat
pause
exit /b 0

rem ---------- download subroutine: %1 remote path, %2 local file ----------
:fetch
curl.exe -sL -o "%~2" "%GITHUB_RAW%/%~1"
if not errorlevel 1 exit /b 0
curl.exe -sL -o "%~2" "%MIRROR_BASE%/%~1"
if not errorlevel 1 exit /b 0
exit /b 1