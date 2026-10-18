@echo off
rem SMW data tool: double-click to turn your own Super Mario Bros. Wonder dump into the game data for /data/SMW.
title SMW data tool
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SMW-Data-Tool.ps1"
echo.
pause
