$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = 'C:\RETRO\e2e-test.log'
Remove-Item $log -Force -ErrorAction SilentlyContinue
# start bridge the same way agent.bat does
$running = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if (-not $running) {
    Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt' -WindowStyle Hidden
    Start-Sleep -Seconds 2
}
$key = (Get-Content 'E:\key.txt')[2].Trim()
# read model from config
$cfg = Get-Content C:\RETRO\config.json -Raw | ConvertFrom-Json
$model = $cfg.transport.api.model
$body = '{"model":"' + $model + '","messages":[{"role":"user","content":"只回复两个字:成功"}]}'
Write-Host "=== e2e via local bridge (model=$model) ==="
& curl.exe -s --noproxy '*' --max-time 60 -X POST http://127.0.0.1:8787/chat/completions -H 'Content-Type: application/json' -H ("Authorization: Bearer " + $key) -d $body
Write-Host ""
Write-Host "=== pipe a chat line into micro-agent (may not read pipes) ==="
$p = Start-Process cmd -ArgumentList ('/c','echo 你好 | C:\RETRO\micro-agent.exe --config C:\RETRO\config.json > ' + $log + ' 2>&1') -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(30000)) { Write-Host 'TIMEOUT(30s) - TUI 等真实控制台,pipetest 跳过'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
else { Write-Host 'pipe test exited'; Get-Content $log | Select-Object -Last 12 }
Remove-Item $log -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Write-Host "=== bridge cleanup done ==="
