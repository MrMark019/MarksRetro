$ErrorActionPreference = 'Stop'
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
$t = $t.Replace('3. 运行 C:\RETRO\agent.bat', '3. 运行 %USERPROFILE%\RETRO\agent.bat')
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 路径已更新'

# === 新版安装验证 ===
cmd /c "E:\retro-install.bat < nul" | Select-String -Pattern 'install dir|base_url|api_key|ERROR'
Write-Host '--- 安装产物 ---'
Get-ChildItem "$env:USERPROFILE\RETRO" | ForEach-Object { $_.Name + '  ' + [math]::Round($_.Length/1KB) + 'KB' }

# === e2e 冒烟(UTF-8 提问,新路径) ===
$maLog = "$env:TEMP\opencode\verify-ma.log"
Remove-Item $maLog -Force -ErrorAction SilentlyContinue
$ask = "$env:TEMP\opencode\verify-ask.txt"
[IO.File]::WriteAllText($ask, "What OS is this? One short English sentence.`r`n", [Text.UTF8Encoding]::new($false))
$p = Start-Process cmd -ArgumentList ('/c','type ' + $ask + ' | "%USERPROFILE%\RETRO\agent.bat" > ' + $maLog + ' 2>&1') -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(90000)) { Write-Host 'TIMEOUT'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Write-Host '--- 应答 ---'
Get-Content $maLog -ErrorAction SilentlyContinue | Select-Object -Last 6
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host '桥未清理!'; Stop-Process -Id $alive.ProcessId -Force } else { Write-Host '桥自动清理 OK' }
