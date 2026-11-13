@echo off
setlocal
set "DIR=%~dp0"
echo Running traced agent for diagnosis, output -> agent-debug.log
echo ==== diag %DATE% %TIME% ==== > "%DIR%agent-debug.log"
cmd /c ""%DIR%agent-traced.bat" < nul " >> "%DIR%agent-debug.log" 2>&1
echo.
echo ============ agent-debug.log (tail 60) ============
powershell -NoProfile -Command "Get-Content '%DIR%agent-debug.log' -Tail 60" 2>nul || more +0 "%DIR%agent-debug.log"
echo.
echo Send this file back: %DIR%agent-debug.log
pause