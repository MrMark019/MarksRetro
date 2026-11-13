$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = "$env:TEMP\opencode\bridge-e3.log"
$t = [IO.File]::ReadAllText($log, [Text.Encoding]::UTF8)
$m = [regex]::Match($t, 'DEBUG body\(4695B\): (\{.*)')
$json = $m.Groups[1].Value
# 截到最后一个 ]} 收尾
$end = $json.LastIndexOf(']}') + 2
$json = $json.Substring(0, $end)
Write-Host "body 长度: $($json.Length) chars"
[IO.File]::WriteAllText("$env:TEMP\opencode\agentbody.json", $json, [Text.UTF8Encoding]::new($false))
# 校验 JSON 合法
try { $null = $json | ConvertFrom-Json; Write-Host 'JSON 合法' } catch { Write-Host "JSON 非法: $_" }

$key = (Get-Content 'E:\key.txt')[2].Trim()
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt' -WindowStyle Hidden
Start-Sleep -Seconds 2
Write-Host '=== 经桥回放(agent 原 body + zig UA) ==='
& curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" -H 'User-Agent: zig/0.15.2 (std.http)' --data-binary "@$env:TEMP\opencode\agentbody.json" http://127.0.0.1:8787/v1/chat/completions | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) }
Write-Host '=== 直连 dashscope 回放(绕过桥) ==='
& curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" --data-binary "@$env:TEMP\opencode\agentbody.json" https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) }
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
