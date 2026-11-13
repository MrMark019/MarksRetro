$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500
$bolog = "$env:TEMP\opencode\bridge-e2e.log"
Remove-Item $bolog -Force -ErrorAction SilentlyContinue
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt' -WindowStyle Hidden -RedirectStandardError $bolog
Start-Sleep -Seconds 2
# clean body-file curl test (no quoting issues)
$key = (Get-Content 'E:\key.txt')[2].Trim()
$cfg = Get-Content C:\RETRO\config.json -Raw | ConvertFrom-Json
[IO.File]::WriteAllText("$env:TEMP\opencode\body.json", ('{"model":"' + $cfg.transport.api.model + '","messages":[{"role":"user","content":"只回复两个字:成功"}]}'), [Text.UTF8Encoding]::new($false))
Write-Host '=== curl via bridge (body file) ==='
& curl.exe -s --noproxy '*' --max-time 60 -X POST http://127.0.0.1:8787/chat/completions -H 'Content-Type: application/json' -H ("Authorization: Bearer " + $key) --data-binary "@$env:TEMP\opencode\body.json"
Write-Host "`n=== micro-agent pipe, capture bridge log ==="
$outlog = "$env:TEMP\opencode\ma-out.log"
Remove-Item $outlog -Force -ErrorAction SilentlyContinue
$p = Start-Process cmd -ArgumentList ('/c','echo 你好 | C:\RETRO\micro-agent.exe --config C:\RETRO\config.json > ' + $outlog + ' 2>&1') -PassThru -WindowStyle Hidden
$null = $p.WaitForExit(40000)
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Write-Host '--- micro-agent output tail ---'
Get-Content $outlog -ErrorAction SilentlyContinue | Select-Object -Last 5
Write-Host '--- bridge log (what paths did agent request?) ---'
Get-Content $bolog -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
