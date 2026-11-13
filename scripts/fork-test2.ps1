$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$src = "$env:TEMP\opencode\zigbuild\retro-agent"
$exe = "$src\zig-out\bin\agentxp.exe"
$bridge = "$env:TEMP\opencode\bridge\retrobridge.exe"
$ca = "$env:TEMP\opencode\bridge\ca-bundle.crt"
$key = (Get-Content 'E:\key.txt')[2].Trim()
$gbk = [System.Text.Encoding]::GetEncoding(936)

Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500
Start-Process $bridge -ArgumentList '-listen','127.0.0.1:8787','-cacert',$ca -WindowStyle Hidden
Start-Sleep -Seconds 2

$cfg = "$env:TEMP\opencode\fc2.json"
'{ "agent": { "name": "m", "mode": "interactive", "system_prompt": "用中文回答,简洁。", "max_history": 20 }, "transport": { "api": { "provider": "openai", "api_key": "", "model": "qwen3.8-flash", "base_url": "http://127.0.0.1:8787", "max_tokens": 128, "context_window": 131072 } }, "security": { "require_approval": false }, "debug_mode": false }' | Out-File $cfg -Encoding ascii

# 单个中文问题(GBK 编码写入)
$inFile = "$env:TEMP\opencode\fc2-in.txt"
[System.IO.File]::WriteAllBytes($inFile, $gbk.GetBytes("请用中文说说北京有什么著名的?一句话`r`n"))
$outFile = "$env:TEMP\opencode\fc2-out.bin"
Remove-Item $outFile -Force -ErrorAction SilentlyContinue

$p = Start-Process $exe -ArgumentList '--config',$cfg,'--key',$key,'-i' -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError "$env:TEMP\opencode\fc2-err.txt" -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

$raw = [System.IO.File]::ReadAllBytes($outFile)
"输出总字节: $($raw.Length)"
# 统计非 ASCII 字节(证明有中文多字节输出,没被剥成 ASCII)
$nonAscii = @($raw | Where-Object { $_ -gt 127 }).Count
"非ASCII字节数: $nonAscii  (>0 说明中文没被剥成 ASCII ✓)"
"=== 按 GBK 解码 ==="
$gbk.GetString($raw)
"=== 按 UTF-8 解码(对照) ==="
[System.Text.Encoding]::UTF8.GetString($raw)
"=== 本机 ACP ==="
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguageID
$acp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP
"ACP=$acp"
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
