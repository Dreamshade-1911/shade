@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM Test suites always build with asserts enabled: the misuse ("death")
REM tests rely on asserts killing the child process.

set SUITE=%1
if "%SUITE%"=="" (
    echo Usage: test.bat ^<suite^>
    echo Suites: lane
    exit /b 1
)

if /I "%SUITE%"=="lane" (
    call :lane
    exit /b !ERRORLEVEL!
)

echo Unknown test suite "%SUITE%".
exit /b 1

REM Suite Handlers

:lane
if not exist bin mkdir bin
odin run tests\lane -out:bin\test_lane.exe -collection:src=src -max-error-count:4 -o:none -debug
exit /b
