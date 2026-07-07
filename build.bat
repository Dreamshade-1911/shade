@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM Default values
set TARGET=galaxy
set MODE=debug

REM Parse arguments
if not "%1"=="" set TARGET=%1
if not "%2"=="" set MODE=%2

REM Mode flags
if /I "%MODE%"=="debug" (
    set MODE_ARGS=-o:none -debug
    where /Q radlink && set MODE_ARGS=!MODE_ARGS! -linker:radlink
) else if /I "%MODE%"=="release" (
    set MODE_ARGS=-microarch:native -o:speed -disable-assert -no-bounds-check
) else if /I "%MODE%"=="shaders" (
    where /Q glslc || (echo glslc not found & exit /b 1)
) else (
    echo Invalid build mode. Use debug or release.
    exit /b 1
)

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

REM Targets

if /I "%TARGET%"=="galaxy" (
    set MODE_ARGS=!MODE_ARGS! -subsystem:windows
    if /I "%MODE%"=="shaders" (
        call :shaders
    ) else (
        call :build
        call :run
    )
    exit /b
)

echo Unknown target.
exit /b 1

REM Target Handlers

:build
if not exist bin mkdir bin
odin build examples\%TARGET% -out:bin\%TARGET%.exe -collection:shade=src -show-timings -max-error-count:4 %MODE_ARGS% && echo Target %TARGET% built successfully.
exit /b

:run
if not exist data mkdir data
xcopy /D /Y "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" bin\
pushd data && ..\bin\%TARGET%.exe & popd
exit /b

:shaders
if not exist data\%TARGET% mkdir data\%TARGET%
set SHADER_COUNT=0
for %%f in (examples\%TARGET%\*.vert) do (
    glslc -fshader-stage=vertex "%%f" -o "data\%TARGET%\%%~nxf.spv"
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!
    set /a SHADER_COUNT+=1
)
for %%f in (examples\%TARGET%\*.frag) do (
    glslc -fshader-stage=fragment "%%f" -o "data\%TARGET%\%%~nxf.spv"
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!
    set /a SHADER_COUNT+=1
)
echo !SHADER_COUNT! shaders built successfully.
exit /b

