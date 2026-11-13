$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$gbk = [System.Text.Encoding]::GetEncoding(936)

# 部署 v2.5
$text = [System.IO.File]::ReadAllText("$env:TEMP\opencode\retro-install-v25.bat", [System.Text.UTF8Encoding]::new($false))
$text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
[System.IO.File]::WriteAllText('E:\retro-install.bat', $text, [System.Text.UTF8Encoding]::new($false))
$b = [System.IO.File]::ReadAllBytes('E:\retro-install.bat')
"v2.5 部署: 非ASCII=" + (@($b | Where-Object { $_ -gt 127 }).Count) + " CRLF=" + ([regex]::Matches([System.Text.Encoding]::ASCII.GetString($b), "`r`n")).Count

# --- 测试1: 便携包正常路径(GBK 中文对话) ---
Write-Host "`n===== T1 便携包 agent.bat 中文对话 =====" -ForegroundColor Yellow
$sim = "$env:TEMP\opencode\ht1"
Remove-Item $sim -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item 'E:\RETRO-X86' $sim -Recurse
$key = (Get-Content 'E:\key.txt')[2].Trim()
[IO.File]::WriteAllText("$sim\key.txt", ($key + "`r`n"), $gbk)
[System.IO.File]::WriteAllBytes("$sim\q.txt", $gbk.GetBytes("用中文一句话介绍杭州`r`n"))
cmd /c "`"$sim\agent.bat`" < `"$sim\q.txt`" > `"$sim\o.bin`" 2>&1"
$raw = [IO.File]::ReadAllBytes("$sim\o.bin")
($gbk.GetString($raw) -split "`n") | Where-Object { $_ -match '[\u4e00-\u9fa5]' -and $_ -notmatch '介绍' } | Select-Object -First 2
"bridge.log 存在: " + (Test-Path "$sim\bridge.log")
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host 'FAIL: 桥未清理'; Stop-Process -Id $alive.ProcessId -Force } else { Write-Host '桥清理 OK' }

# --- 测试2: 桥起不来的失败路径(port=1) ---
Write-Host "`n===== T2 桥失败路径(port=1,应报错驻留) =====" -ForegroundColor Yellow
$sim2 = "$env:TEMP\opencode\ht2"
Remove-Item $sim2 -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item 'E:\RETRO-X86' $sim2 -Recurse
[IO.File]::WriteAllText("$sim2\key.txt", ($key + "`r`n"), $gbk)
$iniTxt = [IO.File]::ReadAllText("$sim2\retro.ini", $gbk) -replace 'port=8787', 'port=1'
[IO.File]::WriteAllText("$sim2\retro.ini", $iniTxt, $gbk)
[System.IO.File]::WriteAllBytes("$sim2\q.txt", $gbk.GetBytes("hi`r`n"))
cmd /c "`"$sim2\agent.bat`" < `"$sim2\q.txt`" > `"$sim2\o.txt`" 2>&1"
Get-Content "$sim2\o.txt" | Select-String -Pattern 'ERROR|did not come' | Select-Object -First 2
"exit 应非0: rc=" + (Get-Content "$sim2\o.txt" | Select-String 'ERROR').Count

# --- 测试3: check.bat 诊断 ---
Write-Host "`n===== T3 check.bat 输出 =====" -ForegroundColor Yellow
cmd /c "`"$sim2\check.bat`" < nul > nul 2>&1"
if (Test-Path "$sim2\check.log") {
    (Get-Content "$sim2\check.log") | Select-String -Pattern '===|rc=' | Select-Object -First 14
} else { "check.log 未生成!" }

# --- 测试4: retro-install v2.5 全流程 ---
Write-Host "`n===== T4 retro-install.bat v2.5 =====" -ForegroundColor Yellow
cmd /c "E:\retro-install.bat < nul" | Select-String -Pattern 'OK|ERROR|WARN|install dir|model|upstream|smoke'
"安装目录: " + ((Get-ChildItem "$env:USERPROFILE\RETRO" -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')

Remove-Item $sim, $sim2 -Recurse -Force -ErrorAction SilentlyContinue
