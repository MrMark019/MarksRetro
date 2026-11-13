$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$src = "$env:TEMP\opencode\zigbuild\retro-agent"
$exe = "$src\zig-out\bin\agentxp.exe"
$bridge = "$env:TEMP\opencode\bridge\retrobridge.exe"
$ca = "$env:TEMP\opencode\bridge\ca-bundle.crt"
$key = (Get-Content 'E:\key.txt')[2].Trim()
$gbk = [System.Text.Encoding]::GetEncoding(936)
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 400
Start-Process $bridge -ArgumentList '-listen','127.0.0.1:8787','-cacert',$ca -WindowStyle Hidden
Start-Sleep -Seconds 2
$cfg = "$env:TEMP\opencode\fc3.json"
'{ "agent": { "name": "m", "mode": "interactive", "max_history": 20 }, "transport": { "api": { "provider": "openai", "api_key": "", "model": "qwen3.8-flash", "base_url": "http://127.0.0.1:8787", "max_tokens": 128, "context_window": 131072 } }, "security": { "require_approval": false } }' | Out-File $cfg -Encoding ascii

foreach ($line in @('/info', '/model deepseek-v4.1-flash', '/model')) {
    $inFile = "$env:TEMP\opencode\fc3-in.txt"
    [System.IO.File]::WriteAllBytes($inFile, $gbk.GetBytes($line + "`n"))
    $outFile = "$env:TEMP\opencode\fc3-out.bin"
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    $p = Start-Process $exe -ArgumentList '--config',$cfg,'--key',$key,'-i' -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError 'NUL' -PassThru -WindowStyle Hidden
    $null = $p.WaitForExit(15000)
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    $txt = $gbk.GetString([System.IO.File]::ReadAllBytes($outFile))
    Write-Host "===== 输入: $line ====="
    # 只打印关键行
    ($txt -split "`n") | Where-Object { $_ -match 'Model|Context|Provider|Endpoint|Switched|Configuration|CONFIG' } | ForEach-Object { $_.Trim() }
}
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
