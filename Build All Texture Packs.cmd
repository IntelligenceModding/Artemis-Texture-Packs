@echo off
setlocal

title Artemis Texture Pack Builder
cd /d "%~dp0"

echo Building all texture packs from resource_packs...
echo Repo: %CD%
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\build-texture-packs.ps1" -Clean
set EXIT_CODE=%ERRORLEVEL%

echo.
if %EXIT_CODE% EQU 0 (
    echo Build completed successfully.
    echo Output zips are in %CD%\build\zips\...
    start "" explorer "%CD%\build\zips"
) else (
    echo Build failed with exit code %EXIT_CODE%.
    echo Run this file from Command Prompt if you need to keep the console open for debugging.
)

echo.
pause
exit /b %EXIT_CODE%
