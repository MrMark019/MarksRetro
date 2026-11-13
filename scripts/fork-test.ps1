$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$src = "$env:TEMP\opencode\zigbuild\retro-agent"
$exe = "$src\zig-out\bin\agentxp.exe"
$bridge = 'C:\Users\<you>\AppData\Local\Temp\opencode\bridge\retrobridge.exe'
$ca = 'C:\Users\<you>\AppData\Local\Temp\opencode\bridge\ca-bundle.crt'
$key = (Get-Content 'E:\key.txt')[2].Trim()

# ???
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500
Start-Process $bridge -ArgumentList '-listen','127.0.0.1:8787','-cacert',$ca -WindowStyle Hidden
Start-Sleep -Seconds 2
"? health: " + (curl.exe -s --noproxy '*' http://127.0.0.1:8787/health)

# ??? config:? max_tokens/context_window,???? qwen3.8-flash
$cfg = "$env:TEMP\opencode\fork-config.json"
@'
{
  "agent": { "name": "micro-agent", "mode": "interactive",
    "system_prompt": "You are a helpful assistant. Reply in the user's language.",
    "max_history": 50 },
  "transport": { "api": {
    "provider": "openai", "api_key": "",
    "model": "qwen3.8-flash",
    "base_url": "http://127.0.0.1:8787",
    "max_tokens": 64,
    "context_window": 131072 } },
  "security": { "require_approval": false, "max_exec_timeout_ms": 30000 },
  "debug_mode": false
}
'@ | Out-File $cfg -Encoding ascii

# ????:? GBK ???? + /model ?? + /info
$gbk = [System.Text.Encoding]::GetEncoding(936)
$inFile = "$env:TEMP\opencode\fork-in.txt"
# ? GBK ???????(?? XP ?????)+ /info ? context_window + /model ?? + ??
$lines = @(
  '?????????',
  '/info',
  '/model deepseek-v4.1-flash',
  '??,1+1?????????'
)
[System.IO.File]::WriteAllBytes($inFile, $gbk.GetBytes(($lines -join "`r`n") + "`r`n"))
"????(GBK)???: " + (Get-Item $inFile).Length

$outFile = "$env:TEMP\opencode\fork-out.txt"
Remove-Item $outFile -Force -ErrorAction SilentlyContinue
$p = Start-Process $exe -ArgumentList '--config', $cfg, '--key', $key, '-i' -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError "$env:TEMP\opencode\fork-err.txt" -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(90000)) { Write-Host 'TIMEOUT'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

"=== ??(? GBK ??,?? XP ????????) ==="
$raw = [System.IO.File]::ReadAllBytes($outFile)
$gbkText = $gbk.GetString($raw)
$gbkText
"=== stderr ==="
Get-Content "$env:TEMP\opencode\fork-err.txt" -ErrorAction SilentlyContinue | Select-Object -First 10
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

