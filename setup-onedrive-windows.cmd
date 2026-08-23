@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-onedrive-windows.ps1" %*
set "setup_exit_code=%ERRORLEVEL%"

echo.
if not "%setup_exit_code%"=="0" (
    echo SecureCRT setup failed. Review the error above.
) else (
    echo You can now launch SecureCRT normally.
)
if not defined CI pause
exit /b %setup_exit_code%
