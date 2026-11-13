@echo on
setlocal enabledelayedexpansion
set "DIR=%~dp0"
set "LOG=%DIR%agent.log"
echo ==== agent.bat %DATE% %TIME% ==== > "%LOG%"

rem ============================================================
rem  XP-safe build: NO nested blocks anywhere.
rem  All parsing runs line-by-line via "call :SUB" subroutines.
rem ============================================================

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

rem ---------- defaults ----------
set MODEL=
set UPSTREAM=
set PORT=8787
set KEYFILE=key.txt
set MAXTOK=0
set CTXW=0
set MAXHIST=100
set APPROVE=false
set BASEURL=

rem ---------- parse retro.ini (one call per line, no blocks) ----------
if not exist "%DIR%retro.ini" goto ini_done
for /f "usebackq eol=; tokens=1,* delims==" %%k in ("%DIR%retro.ini") do call :PARSELINE %%k "%%l"
:ini_done
if not defined UPSTREAM set UPSTREAM=https://dashscope.aliyuncs.com/compatible-mode
if not defined MODEL set MODEL=qwen3.8-flash
if not defined MAXTOK set MAXTOK=0
if not defined CTXW set CTXW=0
if not defined MAXHIST set MAXHIST=100
if not defined BASEURL set BASEURL=http://127.0.0.1:%PORT%
echo ini parsed, model=%MODEL% port=%PORT% >> "%LOG%"

rem ---------- numbered model (arg 1 = number in models.txt) ----------
set PICK=%~1
set SHIFT=
if not defined PICK goto nomenu
echo %PICK%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 goto nomenu
if exist "%DIR%models.txt" for /f "usebackq eol=; tokens=1,* delims==" %%a in ("%DIR%models.txt") do call :FINDMODEL %%a "%%b"
set SHIFT=1
:nomenu

rem ---------- api key: first sk- token, comments stripped ----------
set APIKEY=
if not exist "%DIR%%KEYFILE%" goto key_scan_done
for /f "usebackq tokens=1" %%k in ("%DIR%%KEYFILE%") do call :GETKEY %%k
:key_scan_done
if defined APIKEY goto key_ok
echo [ERROR] No valid sk- key found in %KEYFILE% (first line).
echo key missing in %KEYFILE% >> "%LOG%"
pause
exit /b 2
:key_ok
echo key found, model=%MODEL% bridge=%BASEURL% >> "%LOG%"

rem ---------- runtime config, line by line (no block redirection) ----------
del "%DIR%config.json" >nul 2>nul
>> "%DIR%config.json" echo {
>> "%DIR%config.json" echo   "agent": {
>> "%DIR%config.json" echo     "name": "micro-agent",
>> "%DIR%config.json" echo     "mode": "interactive",
>> "%DIR%config.json" echo     "system_prompt": "You are an AI assistant for this machine. Use your tools to help with files, commands and diagnostics. Reply in the same language the user writes in.",
>> "%DIR%config.json" echo     "max_history": %MAXHIST%
>> "%DIR%config.json" echo   },
>> "%DIR%config.json" echo   "transport": {
>> "%DIR%config.json" echo     "api": {
>> "%DIR%config.json" echo       "provider": "openai",
>> "%DIR%config.json" echo       "api_key": "",
>> "%DIR%config.json" echo       "model": "%MODEL%",
>> "%DIR%config.json" echo       "base_url": "%BASEURL%",
>> "%DIR%config.json" echo       "max_tokens": %MAXTOK%,
>> "%DIR%config.json" echo       "context_window": %CTXW%
>> "%DIR%config.json" echo     }
>> "%DIR%config.json" echo   },
>> "%DIR%config.json" echo   "security": {
>> "%DIR%config.json" echo     "require_approval": %APPROVE%,
>> "%DIR%config.json" echo     "max_exec_timeout_ms": 30000
>> "%DIR%config.json" echo   },
>> "%DIR%config.json" echo   "debug_mode": false
>> "%DIR%config.json" echo }
echo config.json written >> "%LOG%"

echo   model: %MODEL%   bridge: %BASEURL%   upstream: %UPSTREAM%
echo.

rem ---------- bridge: probe, start, wait ----------
set LISTEN=%BASEURL:http://=%
"%DIR%retrobridge.exe" -ping -listen %LISTEN% >nul 2>nul
if not errorlevel 3 goto ready
echo starting bridge >> "%LOG%"
start "" /min "%DIR%retrobridge.exe" -listen 127.0.0.1:%PORT% -upstream "%UPSTREAM%" -cacert "%DIR%ca-bundle.crt" -log "%DIR%bridge.log"
set TRIES=0
:probe
ping -n 2 127.0.0.1 >nul
"%DIR%retrobridge.exe" -ping -listen 127.0.0.1:%PORT% >nul 2>nul
if not errorlevel 3 goto ready
set /a TRIES+=1
if %TRIES% LSS 12 goto probe
echo [ERROR] TLS bridge did not come up on port %PORT%.
echo         Open %DIR%bridge.log and %DIR%agent.log, then run check.bat.
echo bridge failed to start >> "%LOG%"
pause
exit /b 5
:ready
echo bridge ready, launching micro-agent >> "%LOG%"

rem ---------- run agent ----------
if defined SHIFT goto run_shift
"%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %*
goto run_done
:run_shift
"%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %2 %3 %4 %5
:run_done
set RC=%ERRORLEVEL%
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul
echo micro-agent exited rc=%RC% >> "%LOG%"
if "%RC%"=="0" goto fin
echo.
echo [ERROR] micro-agent exited with code %RC% ^(expected 0^).
echo         See %DIR%agent.log and %DIR%bridge.log, or run check.bat.
pause
:fin
exit /b %RC%

rem ============================================================
rem  subroutines (never fall through into them)
rem ============================================================

:PARSELINE
set "K=%~1"
set "V=%~2"
if /i "%K%"=="model" set MODEL=%V%
if /i "%K%"=="upstream" set UPSTREAM=%V%
if /i "%K%"=="port" set PORT=%V%
if /i "%K%"=="base_url" set BASEURL=%V%
if /i "%K%"=="key_file" set KEYFILE=%V%
if /i "%K%"=="max_tokens" set MAXTOK=%V%
if /i "%K%"=="context_window" set CTXW=%V%
if /i "%K%"=="max_history" set MAXHIST=%V%
if /i "%K%"=="require_approval" set APPROVE=%V%
goto :eof

:FINDMODEL
if "%~1"=="%PICK%" set MODEL=%~2
goto :eof

:GETKEY
if defined APIKEY goto :eof
set "CAND=%~1"
if not defined CAND goto :eof
echo %CAND%| findstr /b "sk-" >nul
if errorlevel 1 goto :eof
set APIKEY=%CAND%
goto :eof
