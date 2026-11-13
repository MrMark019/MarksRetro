$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$gbk = [System.Text.Encoding]::GetEncoding(936)

# 1) agent-traced.bat = agent.bat 开 @echo on
$src = [IO.File]::ReadAllText('E:\RETRO-X86\agent.bat', [System.Text.Encoding]::ASCII)
$traced = $src -replace '^@echo off', '@echo on'
[IO.File]::WriteAllText('E:\RETRO-X86\agent-traced.bat', $traced, [System.Text.Encoding]::ASCII)

# 2) diag.bat:跑 traced 版,全量输出进 agent-debug.log,再显示
$diag = @'
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
'@
$diag = $diag -replace "`r`n", "`n" -replace "`n", "`r`n"
$b = [System.Text.Encoding]::ASCII.GetBytes($diag)
if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'not ascii' }
[IO.File]::WriteAllBytes('E:\RETRO-X86\diag.bat', $b)

'已生成: E:\RETRO-X86\agent-traced.bat + diag.bat'
Get-ChildItem 'E:\RETRO-X86' -File | Where-Object { $_.Name -match 'diag|traced' } | ForEach-Object { $_.Name + '  ' + $_.Length + 'B' }
