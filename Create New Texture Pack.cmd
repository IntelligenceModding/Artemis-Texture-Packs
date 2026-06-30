@echo off
setlocal

title Artemis Texture Pack Scaffold
cd /d "%~dp0"

set /p PACK_NAME=Enter the new resource pack name: 
if "%PACK_NAME%"=="" (
    echo No pack name entered.
    echo.
    pause
    exit /b 1
)

set /p MIN_VERSION=Minimum Minecraft version [1.13]: 
if "%MIN_VERSION%"=="" set MIN_VERSION=1.13

echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\new-texture-pack.ps1" -Name "%PACK_NAME%" -MinVersion "%MIN_VERSION%"
set EXIT_CODE=%ERRORLEVEL%

echo.
if %EXIT_CODE% EQU 0 (
    echo Resource pack scaffold created successfully.
) else (
    echo Failed to create resource pack scaffold. Exit code %EXIT_CODE%.
)

echo.
pause
exit /b %EXIT_CODE%
