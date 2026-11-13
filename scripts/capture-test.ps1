$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$go = "$env:TEMP\opencode\go110\go\bin"; $src = "$env:TEMP\opencode\bridge"
$env:GOPATH = "$src\gopath"
Push-Location $src; & "$go\go.exe" build -o retrobridge.exe main.go; Pop-Location
Copy-Item "$src\retrobridge.exe" 'C:\RETRO\retrobridge.exe' -Force
Remove-Item 'C:\RETRO\agent-body-capture.bin' -Force -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt','-debug' -WindowStyle Hidden -RedirectStandardError "$env:TEMP\opencode\bridge-e4.log"
Start-Sleep -Seconds 2
# 触发一次 agent 请求以生成 capture
$null = (Start-Process cmd -ArgumentList '/c','echo 你好 | C:\RETRO\micro-agent.exe --config C:\RETRO\config.json > nul 2>&1' -PassThru -WindowStyle Hidden).WaitForExit(40000)
Start-Sleep -Seconds 1

$cap = 'C:\RETRO\agent-body-capture.bin'
if (-not (Test-Path $cap)) { Write-Host '无 capture!'; exit 1 }
$bytes = [IO.File]::ReadAllBytes($cap)
Write-Host "capture 字节数: $($bytes.Length)"
# 控制字符扫描
$ctrl = @()
for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -lt 32 -and $bytes[$i] -ne 10 -and $bytes[$i] -ne 13 -and $bytes[$i] -ne 9) { $ctrl += "$i=0x{0:X2}" -f $bytes[$i] } }
Write-Host "控制字符: $(if ($ctrl.Count) { ($ctrl | Select-Object -First 10) -join ' ' } else { '无' })"
# UTF-8 合法性
$txt = [Text.Encoding]::UTF8.GetString($bytes)
Write-Host "UTF8 解码后字符数: $($txt.Length)"
try { $o = $txt | ConvertFrom-Json; Write-Host "JSON 合法, tools=$($o.tools.Count), user内容=$($o.messages[1].content)" } catch { Write-Host "JSON 解析失败: $_" }

$key = (Get-Content 'E:\key.txt')[2].Trim()
Write-Host '=== 用 capture 原字节经桥回放 ==='
& curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" --data-binary "@$cap" http://127.0.0.1:8787/v1/chat/completions | ForEach-Object { $_.Substring(0, [Math]::Min(180, $_.Length)) }
Write-Host '=== 用 capture 原字节直连 dashscope ==='
& curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" --data-binary "@$cap" https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions | ForEach-Object { $_.Substring(0, [Math]::Min(180, $_.Length)) }
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
