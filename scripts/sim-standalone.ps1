$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$sim = "$env:TEMP\opencode\sim-copy"
Remove-Item $sim -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item 'E:\RETRO-X86' $sim -Recurse
# 模拟用户:把真实 key(E:\key.txt 第三行)粘进副本的 key.txt
$key = (Get-Content 'E:\key.txt')[2].Trim()
[IO.File]::WriteAllText("$sim\key.txt", ($key + "`r`n"), [Text.Encoding]::GetEncoding(936))
Write-Host '=== 1) setup.bat(副本) ==='
cmd /c "`"$sim\setup.bat`" < nul" | Select-String -Pattern 'OK|ERROR|model|base_url|api_key|complete'
Write-Host '=== 2) config.json 已生成? ==='
$cfg = Get-Content "$sim\config.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($cfg) { "provider=$($cfg.transport.api.provider) model=$($cfg.transport.api.model) base=$($cfg.transport.api.base_url) key=$($cfg.transport.api.api_key.Substring(0,7))***" } else { 'config 未生成!' }
Write-Host '=== 3) agent.bat 端到端 ==='
$ask = "$env:TEMP\opencode\sim-ask.txt"
[IO.File]::WriteAllText($ask, "What OS is this? One short English sentence.`r`n", [Text.UTF8Encoding]::new($false))
$maLog = "$env:TEMP\opencode\sim-ma.log"
Remove-Item $maLog -Force -ErrorAction SilentlyContinue
$p = Start-Process cmd -ArgumentList ('/c','type ' + $ask + ' | "' + $sim + '\agent.bat" > ' + $maLog + ' 2>&1') -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(90000)) { Write-Host 'TIMEOUT'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Get-Content $maLog | Select-Object -Last 5
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host '桥未清理!'; Stop-Process -Id $alive.ProcessId -Force } else { Write-Host '桥自动清理 OK' }
# 副本用完即弃
Remove-Item $sim -Recurse -Force
Write-Host '=== 4) 母盘 key.txt 仍是占位(无真实密钥) ==='
Get-Content 'E:\RETRO-X86\key.txt' -Encoding Default
