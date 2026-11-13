$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- 加固版 agent.bat:tokens=1 去注释 + 全程写 agent.log ----------
$agent = @'
@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"
set "LOG=%DIR%agent.log"
echo ==== agent.bat %DATE% %TIME% ==== > "%LOG%"

rem ---------- clock guard ----------
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [WARN] System clock wrong. Trying NTP sync...
echo clock wrong, trying NTP >> "%LOG%"
net time /setsntp:ntp.aliyun.com >> "%LOG%" 2>&1
w32tm /resync /force >> "%LOG%" 2>&1
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [ERROR] Clock still wrong - TLS cert checks WILL fail.
echo         Fix date/time manually, or replace the CMOS battery.
echo clock still wrong, abort >> "%LOG%"
pause
exit /b 7
:c_ok
echo clock ok >> "%LOG%"

rem ---------- parse retro.ini ----------
set MODEL=
set UPSTREAM=
set PORT=8787
set KEYFILE=key.txt
set MAXTOK=0
set CTXW=0
set MAXHIST=100
set APPROVE=false
set BASEURL=
if exist "%DIR%retro.ini" (
    for /f "usebackq eol=; tokens=1,* delims==" %%k in ("%DIR%retro.ini") do (
        set "K=%%k"
        set "V=%%l"
        if /i "!K!"=="model" set MODEL=!V!
        if /i "!K!"=="upstream" set UPSTREAM=!V!
        if /i "!K!"=="port" set PORT=!V!
        if /i "!K!"=="base_url" set BASEURL=!V!
        if /i "!K!"=="key_file" set KEYFILE=!V!
        if /i "!K!"=="max_tokens" set MAXTOK=!V!
        if /i "!K!"=="context_window" set CTXW=!V!
        if /i "!K!"=="max_history" set MAXHIST=!V!
        if /i "!K!"=="require_approval" set APPROVE=!V!
    )
)
if not defined UPSTREAM set UPSTREAM=https://dashscope.aliyuncs.com/compatible-mode
if not defined MODEL set MODEL=qwen3.8-flash
if not defined MAXTOK set MAXTOK=0
if not defined CTXW set CTXW=0
if not defined MAXHIST set MAXHIST=100
if not defined BASEURL set BASEURL=http://127.0.0.1:%PORT%

rem ---------- numbered model ----------
set PICK=%~1
set SHIFT=
if defined PICK (
    echo %PICK%| findstr /r "^[0-9][0-9]*$" >nul && (
        if exist "%DIR%models.txt" (
            for /f "usebackq eol=; tokens=1,* delims==" %%a in ("%DIR%models.txt") do (
                if "%%a"=="%PICK%" set MODEL=%%b
            )
        )
        set SHIFT=1
    )
)

rem ---------- api key: first sk- token, comments/whitespace stripped ----------
set APIKEY=
if exist "%DIR%%KEYFILE%" (
    for /f "usebackq tokens=1" %%k in ("%DIR%%KEYFILE%") do (
        if not defined APIKEY (echo %%k| findstr /b "sk-" >nul && set "APIKEY=%%k")
    )
)
if not defined APIKEY (
    echo [ERROR] No valid sk- key found in %KEYFILE% (first line).
    echo key missing in %KEYFILE% >> "%LOG%"
    pause
    exit /b 2
)
echo key found, model=!MODEL! bridge=!BASEURL! >> "%LOG%"

rem ---------- runtime config ----------
> "%DIR%config.json" (
    echo {
    echo   "agent": {
    echo     "name": "micro-agent",
    echo     "mode": "interactive",
    echo     "system_prompt": "You are an AI assistant for this machine. Use your tools to help with files, commands and diagnostics. Reply in the same language the user writes in.",
    echo     "max_history": %MAXHIST%
    echo   },
    echo   "transport": {
    echo     "api": {
    echo       "provider": "openai",
    echo       "api_key": "",
    echo       "model": "%MODEL%",
    echo       "base_url": "%BASEURL%",
    echo       "max_tokens": %MAXTOK%,
    echo       "context_window": %CTXW%
    echo     }
    echo   },
    echo   "security": {
    echo     "require_approval": %APPROVE%,
    echo     "max_exec_timeout_ms": 30000
    echo   },
    echo   "debug_mode": false
    echo }
)

echo   model: %MODEL%   bridge: %BASEURL%   upstream: %UPSTREAM%
echo.

rem ---------- bridge: probe, start, wait ----------
"%DIR%retrobridge.exe" -ping -listen %BASEURL:http://=% >nul 2>nul
if not errorlevel 3 goto ready
echo starting bridge >> "%LOG%"
start "" /min "%DIR%retrobridge.exe" -listen 127.0.0.1:%PORT% -upstream "%UPSTREAM%" -cacert "%DIR%ca-bundle.crt" -log "%DIR%bridge.log"
set TRIES=0
:probe
ping -n 2 127.0.0.1 >nul
"%DIR%retrobridge.exe" -ping -listen 127.0.0.1:%PORT% >nul 2>nul
if not errorlevel 3 goto ready
set /a TRIES+=1
if !TRIES! LSS 12 goto probe
echo [ERROR] TLS bridge did not come up on port %PORT%.
echo         Open %DIR%bridge.log and %DIR%agent.log, then run check.bat.
echo bridge failed to start >> "%LOG%"
pause
exit /b 5
:ready
echo bridge ready, launching micro-agent >> "%LOG%"

if defined SHIFT (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %2 %3 %4 %5
) else (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %*
)
set RC=%ERRORLEVEL%
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul
echo micro-agent exited rc=%RC% >> "%LOG%"
if not "%RC%"=="0" (
    echo.
    echo [ERROR] micro-agent exited with code %RC% ^(expected 0^).
    echo         See %DIR%agent.log and %DIR%bridge.log, or run check.bat.
    pause
)
'@
$agent = $agent -replace "`r`n", "`n" -replace "`n", "`r`n"
$b = [Text.Encoding]::ASCII.GetBytes($agent)
if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'not ASCII' }
[IO.File]::WriteAllBytes('E:\RETRO-X86\agent.bat', $b)
[IO.File]::WriteAllBytes('E:\opencode\retro\agent.bat.template', $b)
'agent.bat 加固版已部署(tokens=1去注释 + agent.log)'
