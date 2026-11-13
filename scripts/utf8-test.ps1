$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-Item 'C:\RETRO\agent-body-capture.bin' -Force -ErrorAction SilentlyContinue
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt','-debug' -WindowStyle Hidden -RedirectStandardError "$env:TEMP\opencode\bridge-e5.log"
Start-Sleep -Seconds 2

# 用 UTF-8 字节喂 stdin(模拟真实控制台 ReadConsoleW 转换后的效果)
$utf8File = "$env:TEMP\opencode\ask-utf8.txt"
[IO.File]::WriteAllText($utf8File, "用一句话介绍你自己`r`n", [Text.UTF8Encoding]::new($false))

$cmd = '/c','type ' + $utf8File + ' | C:\RETRO\micro-agent.exe --config C:\RETRO\config.json > ' + "$env:TEMP\opencode\ma-e5.log" + ' 2>&1'
$p = Start-Process cmd -ArgumentList $cmd -PassThru -WindowStyle Hidden
$null = $p.WaitForExit(60000)
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

Write-Host '--- micro-agent 输出尾部 ---'
Get-Content "$env:TEMP\opencode\ma-e5.log" -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 8
Write-Host '--- bridge 日志 ---'
Get-Content "$env:TEMP\opencode\bridge-e5.log" -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern 'FORENSIC|->|400|200' | Select-Object -Last 4 | ForEach-Object { $_.Line }
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
