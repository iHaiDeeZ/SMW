@echo off
rem SMW data tool: double-click to open the window that turns your own Super Mario Bros. Wonder dump into the game
rem data for /data/SMW (and uploads it to your PS4 if you like).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SMW-Data-Tool.ps1"
