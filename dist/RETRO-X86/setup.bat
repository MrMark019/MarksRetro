@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"
echo.
echo ============================================
echo   RETRO standalone setup v2 (check only)
echo ============================================
echo.

"%DIR%retrobridge.exe" -check >nul 2>nul
if errorlevel 3 (
    echo [WARN] System clock wrong. Trying NTP sync...
    net time /setsntp:ntp.aliyun.com >nul 2>nul
    w32tm /resync /force >nul 2>nul
    "%DIR%retrobridge.exe" -check >nul 2>nul
    if errorlevel 3 (echo [ERROR] Clock still wrong - fix it first ^(taskbar clock or CMOS battery^). & pause & exit /b 7)
)
echo [OK] Clock fine

"%DIR%micro-agent.exe" --version >nul 2>nul
if errorlevel 1 (echo [ERROR] micro-agent.exe cannot run here. & pause & exit /b 1)
echo [OK] micro-agent runs
echo.

if not exist "%DIR%retro.ini" (echo [ERROR] retro.ini missing. & pause & exit /b 2)
set KEYFILE=key.txt
for /f "usebackq eol=; tokens=1,* delims==" %%k in ("%DIR%retro.ini") do (
    set "K=%%k"
    if /i "!K!"=="key_file" set KEYFILE=%%l
    if /i "!K!"=="model" set MODEL=%%l
    if /i "!K!"=="upstream" set UPSTREAM=%%l
    if /i "!K!"=="port" set PORT=%%l
)
if not defined UPSTREAM set UPSTREAM=https://dashscope.aliyuncs.com/compatible-mode
if not defined PORT set PORT=8787
set APIKEY=
if exist "%DIR%%KEYFILE%" (
    for /f "usebackq delims=" %%k in ("%DIR%%KEYFILE%") do (
        if not defined APIKEY (echo %%k| findstr /b "sk-" >nul && set "APIKEY=%%k")
    )
)
if not defined APIKEY (
    echo [WARN] No sk- key yet. Edit %KEYFILE% first line, then run agent.bat.
) else (
    echo [OK] Key present: !APIKEY:~0,7!***
)
echo   model    : %MODEL%
echo   upstream : %UPSTREAM%
echo   bridge   : http://127.0.0.1:%PORT%
echo.
echo   Ready. Double-click agent.bat to chat ^(agent.bat 2 = menu model #2^).
pause >nul