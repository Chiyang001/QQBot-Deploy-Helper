@echo off
setlocal EnableExtensions
cd /d "%~dp0"
chcp 65001 >nul
title ChiXiaoYang Uninstall - AstrBot + NapCat QQ
color 07

cls
echo.
echo   ================================================================
echo     ChiXiaoYang QQ Bot Uninstall Helper
echo   ================================================================
echo     WARNING: This cannot be undone automatically.
echo     You must type YES to delete anything.
echo   ================================================================
echo.

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
  color 0C
  echo   Uninstall failed. Exit code: %ERR%
  echo   Check errors above, or open the logs folder.
  echo.
  pause
  exit /b %ERR%
)

color 0E
echo   Uninstall finished. You can run deploy again anytime.
echo.
pause
exit /b 0
