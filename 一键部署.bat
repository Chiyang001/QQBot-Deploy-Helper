@echo off
setlocal EnableExtensions
cd /d "%~dp0"
chcp 65001 >nul
title ChiXiaoYang Deploy - AstrBot + NapCat QQ
color 07

cls
echo.
echo   ================================================================
echo     ChiXiaoYang QQ Bot Deploy Helper
echo     AstrBot + NapCat QQ
echo   ================================================================
echo.

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" %*
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
  color 0C
  echo   Deploy failed. Exit code: %ERR%
  echo   Scroll up for errors, or open the logs folder.
  echo.
  pause
  exit /b %ERR%
)

color 0A
echo   Deploy finished. If you saw Bingo above, it succeeded.
echo.
pause
exit /b 0
