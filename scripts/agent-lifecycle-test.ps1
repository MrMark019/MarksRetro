$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "=== run agent.bat (bridge lifecycle test) ==="
$p = Start-Process cmd -ArgumentList '/c','C:\RETRO\agent.bat < nul > C:\RETRO\agent-test.log 2>&1' -PassThru -WindowStyle Hidden
$seen = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    $h = & curl.exe -s --noproxy '*' --max-time 2 http://127.0.0.1:8787/health 2>$null
    if ($h -eq 'ok') { $seen = $true; Write-Host ("bridge up after {0}s, /health=ok" -f (($i+1)*0.5)); break }
}
if (-not $seen) { Write-Host "WARN: bridge never observed" }
$exited = $p.WaitForExit(40000)
if (-not $exited) {
    Write-Host "agent still running (waiting console?) - forcing end"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'micro-agent.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 3
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host "bridge STILL RUNNING PID=$($alive.ProcessId) - cleanup failed" } else { Write-Host "bridge auto-cleaned OK" }
Write-Host "--- agent-test.log ---"
Get-Content C:\RETRO\agent-test.log -ErrorAction SilentlyContinue | Select-Object -First 8
Remove-Item C:\RETRO\agent-test.log -Force -ErrorAction SilentlyContinue
