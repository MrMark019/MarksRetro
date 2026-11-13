$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$maLog = "$env:TEMP\opencode\final-ma.log"
Remove-Item $maLog -Force -ErrorAction SilentlyContinue
$ask = "$env:TEMP\opencode\final-ask.txt"
[IO.File]::WriteAllText($ask, "What is this machine's OS? Answer in one short English sentence.`r`n", [Text.UTF8Encoding]::new($false))
Write-Host '=== 生产版 agent.bat 全链路(英文提问,含工具调用) ==='
$p = Start-Process cmd -ArgumentList ('/c','type ' + $ask + ' | C:\RETRO\agent.bat > ' + $maLog + ' 2>&1') -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(90000)) { Write-Host 'TIMEOUT 90s'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Write-Host '--- 输出尾部 ---'
Get-Content $maLog -ErrorAction SilentlyContinue | Select-Object -Last 10
Write-Host '--- 桥是否已被 agent.bat 自动清理 ---'
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host "桥仍在运行 PID=$($alive.ProcessId)"; Stop-Process -Id $alive.ProcessId -Force } else { Write-Host '已自动清理 ✓' }
