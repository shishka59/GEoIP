@echo off
echo Generating expanded DNS database...
echo.

REM Check if Node.js is installed
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo Node.js is not installed or not in PATH
    echo Please install Node.js from https://nodejs.org/
    pause
    exit /b 1
)

REM Run the generator
node generate-dns.js

if %errorlevel% equ 0 (
    echo.
    echo DNS database generation completed successfully!
) else (
    echo.
    echo Error occurred during generation.
)

pause
