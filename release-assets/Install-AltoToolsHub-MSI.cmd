@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AltoToolsHub-MSI.ps1" %*
set "helper_exit=%errorlevel%"
if not "%helper_exit%"=="0" (
  echo.
  echo Installation helper failed with exit code %helper_exit%.
  pause
)
exit /b %helper_exit%
