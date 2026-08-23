@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0disconnect-onedrive-windows.ps1" %*
set "disconnect_exit_code=%ERRORLEVEL%"

echo.
if not "%disconnect_exit_code%"=="0" (
    echo SecureCRT disconnect failed. Review the error above.
) else (
    echo SecureCRT disconnect finished.
)
if not defined CI pause
exit /b %disconnect_exit_code%
