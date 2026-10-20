@echo off
rem Starts the game for a debug play: -debug, windowed, on the main menu (no save opened), as "pzdev.py open" does.
rem The user's own options (borderless, size) and latest save are put back when the game ends, however it ends.
cd /d "%~dp0"
python pzdev.py open
if errorlevel 1 pause
