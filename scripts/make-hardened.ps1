$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- 加固版 agent.bat(独立包与安装产物共用同一份) ----------
$agent = @'
@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"

rem ---------- clock guard ----------
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [WARN] System clock wrong. Trying NTP sync...
net time /setsntp:ntp.aliyun.com >nul 2>nul
w32tm /resync /force >nul 2>nul
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [ERROR] Clock still wrong - TLS cert checks WILL fail.
echo         Fix date/time manually, or replace the CMOS battery.
pause
exit /b 7
:c_ok

rem ---------- parse retro.ini (if present; else defaults) ----------
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

rem ---------- numbered model from models.txt:  agent.bat 2 ----------
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

rem ---------- api key from key_file (never stored into config.json) ----------
set APIKEY=
if exist "%DIR%%KEYFILE%" (
    for /f "usebackq delims=" %%k in ("%DIR%%KEYFILE%") do (
        if not defined APIKEY (echo %%k| findstr /b "sk-" >nul && set "APIKEY=%%k")
    )
)
if not defined APIKEY (
    echo [ERROR] No valid sk- key found in %KEYFILE% (first line).
    pause
    exit /b 2
)

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

rem ---------- bridge: probe, start, wait for ready ----------
"%DIR%retrobridge.exe" -ping -listen %BASEURL:http://=% >nul 2>nul
if not errorlevel 3 goto ready
start "" /min "%DIR%retrobridge.exe" -listen 127.0.0.1:%PORT% -upstream "%UPSTREAM%" -cacert "%DIR%ca-bundle.crt" -log "%DIR%bridge.log"
set TRIES=0
:probe
ping -n 2 127.0.0.1 >nul
"%DIR%retrobridge.exe" -ping -listen 127.0.0.1:%PORT% >nul 2>nul
if not errorlevel 3 goto ready
set /a TRIES+=1
if !TRIES! LSS 12 goto probe
echo [ERROR] TLS bridge did not come up on port %PORT%.
echo         Open %DIR%bridge.log - if it is missing or empty,
echo         retrobridge.exe itself cannot run on this system.
echo         Run check.bat for a full diagnosis.
pause
exit /b 5

:ready
if defined SHIFT (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %2 %3 %4 %5
) else (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %*
)
set RC=%ERRORLEVEL%
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul
if not "%RC%"=="0" (
    echo.
    echo [ERROR] micro-agent exited with code %RC% ^(expected 0^).
    echo         Run check.bat in this folder and send back check.log.
    pause
)
'@
$agent = $agent -replace "`r`n", "`n" -replace "`n", "`r`n"
$b = [Text.Encoding]::ASCII.GetBytes($agent)
if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'agent.bat not ASCII' }
[IO.File]::WriteAllBytes('E:\RETRO-X86\agent.bat', $b)
[IO.File]::WriteAllBytes('E:\opencode\retro\agent.bat.template', $b)
'agent.bat(加固版)已部署: RETRO-X86 + opencode\retro\agent.bat.template'

# ---------- check.bat 诊断脚本 ----------
$check = @'
@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"
if not "%LOGGED%"=="1" (
    set LOGGED=1
    cmd /c call "%~f0" > "%DIR%check.log" 2>&1
    type "%DIR%check.log"
    echo.
    echo ============================================================
    echo  results saved to %DIR%check.log
    echo  send that file back for diagnosis.
    echo ============================================================
    pause
    exit /b
)
echo === RETRO diagnostics %DATE% %TIME% ===
echo.
echo === 1) clock check (retrobridge -check) ===
"%DIR%retrobridge.exe" -check
echo rc=%ERRORLEVEL%
echo.
echo === 2) retrobridge supports -ping (new build) ===
"%DIR%retrobridge.exe" -ping
echo rc=%ERRORLEVEL% (3=no bridge running, that is fine here)
echo.
echo === 3) start bridge manually ===
start "" /min "%DIR%retrobridge.exe" -listen 127.0.0.1:8787 -upstream https://dashscope.aliyuncs.com/compatible-mode -cacert "%DIR%ca-bundle.crt" -log "%DIR%bridge.log"
ping -n 4 127.0.0.1 >nul
"%DIR%retrobridge.exe" -ping
echo rc=%ERRORLEVEL% (0 = bridge up OK, 3 = bridge FAILED to start)
echo.
echo === 4) micro-agent fork --version ===
"%DIR%micro-agent.exe" --version
echo rc=%ERRORLEVEL%
echo.
echo === 5) micro-agent stock --version (official build for comparison) ===
if exist "%DIR%micro-agent.exe.stock" (
    "%DIR%micro-agent.exe.stock" --version
    echo rc=%ERRORLEVEL%
) else (
    echo ^(no stock binary in this folder^)
)
echo.
echo === 6) key.txt sanity ===
findstr /b "sk-" "%DIR%key.txt" >nul && (echo key line found) || (echo KEY MISSING or placeholder)
echo.
echo === 7) bridge.log tail ===
if exist "%DIR%bridge.log" (
    powershell -NoProfile -Command "Get-Content '%DIR%bridge.log' -Tail 5" 2>nul || type "%DIR%bridge.log"
) else (
    echo (no bridge.log yet)
)
echo.
echo === done ===
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul
'@
$check = $check -replace "`r`n", "`n" -replace "`n", "`r`n"
$b2 = [Text.Encoding]::ASCII.GetBytes($check)
if (@($b2 | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'check.bat not ASCII' }
[IO.File]::WriteAllBytes('E:\RETRO-X86\check.bat', $b2)
[IO.File]::WriteAllBytes('E:\opencode\retro\check.bat.template', $b2)
'check.bat 已部署'
