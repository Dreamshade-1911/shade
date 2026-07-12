@echo off
setlocal

if not exist "bin" mkdir "bin"
if not exist "data" mkdir "data"

REM Resolve ODIN_ROOT if not set
if "%ODIN_ROOT%"=="" (
    for /f "delims=" %%i in ('where odin 2^>nul') do set "ODIN_ROOT=%%~dpi"
    if "!ODIN_ROOT!"=="" (
        echo Error: ODIN_ROOT is not set and odin was not found in PATH.
        exit /b 1
    )
    REM Strip trailing backslash
    if "!ODIN_ROOT:~-1!"=="\" set "ODIN_ROOT=!ODIN_ROOT:~0,-1!"
)
xcopy /D /Y "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" bin\

rem Rebuild meta only when the executable is missing or meta.odin is newer than it.
set "BUILD="
if not exist "bin\meta.exe" (
    set "BUILD=1"
) else (
    rem Exe exists: rebuild only if meta.odin is newer than it.
    xcopy /L /D /Y "meta.odin" "bin\meta.exe" | findstr /B /C:"1 " >nul && set "BUILD=1"
)

if defined BUILD (
    echo Building meta program...
    odin build meta.odin -file -out:bin\meta.exe
    if errorlevel 1 (
        echo Meta program compilation failed.
        exit /b 1
    )
)

bin\meta.exe %*
