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
echo (logs live next to the bat you run: agent.log / bridge.log / check.log here)
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul