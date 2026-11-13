$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500
$bolog = "$env:TEMP\opencode\bridge-e3.log"
$outlog = "$env:TEMP\opencode\ma-e3.log"
Remove-Item $bolog, $outlog -Force -ErrorAction SilentlyContinue
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt','-debug' -WindowStyle Hidden -RedirectStandardError $bolog
Start-Sleep -Seconds 2
Write-Host '=== micro-agent pipe e2e (question: 用一句话介绍你自己) ==='
$p = Start-Process cmd -ArgumentList ('/c','echo 用一句话介绍你自己 | C:\RETRO\micro-agent.exe --config C:\RETRO\config.json > ' + $outlog + ' 2>&1') -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(60000)) { Write-Host 'TIMEOUT 60s'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Write-Host '--- micro-agent output ---'
Get-Content $outlog -ErrorAction SilentlyContinue | Select-Object -Last 14
Write-Host '--- bridge log ---'
Get-Content $bolog -ErrorAction SilentlyContinue | Select-Object -Last 5
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
