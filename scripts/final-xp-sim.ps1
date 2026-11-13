$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$gbk = [System.Text.Encoding]::GetEncoding(936)
$sim = "$env:TEMP\opencode\sim-xp"
Remove-Item $sim -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item 'E:\RETRO-X86' $sim -Recurse
$key = (Get-Content 'E:\key.txt')[2].Trim()
[IO.File]::WriteAllText("$sim\key.txt", ($key + "`r`n"), $gbk)

# 1) setup.bat
cmd /c "`"$sim\setup.bat`" < nul" | Select-String -Pattern 'OK|ERROR|WARN|model|base_url|Ready'

# 2) agent.bat:GBK 中文问题经 stdin(最接近 XP 控制台真实字节流)
$inFile = "$env:TEMP\opencode\sim-xp-in.txt"
[System.IO.File]::WriteAllBytes($inFile, $gbk.GetBytes("用中文一句话介绍上海`r`n"))
$outFile = "$env:TEMP\opencode\sim-xp-out.bin"
Remove-Item $outFile -Force -ErrorAction SilentlyContinue
$p = Start-Process cmd -ArgumentList '/c', "`"$sim\agent.bat`" < `"$inFile`" > `"$outFile`" 2>&1" -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(90000)) { Write-Host 'TIMEOUT'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$raw = [IO.File]::ReadAllBytes($outFile)
$na = @($raw | Where-Object { $_ -gt 127 }).Count
"输出 $(( $raw.Length ))B,非ASCII $na 个"
"=== GBK 解码输出(尾部) ==="
($gbk.GetString($raw) -split "`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 4

# 3) 桥清理确认
$alive = Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'"
if ($alive) { Write-Host '桥未清理!'; Stop-Process -Id $alive.ProcessId -Force } else { Write-Host '桥自动清理 OK' }
# 4) config.json 无密钥确认
$cfgTxt = [IO.File]::ReadAllText("$sim\config.json")
"config.json 含密钥? " + [bool]($cfgTxt -match 'sk-[a-z0-9]{8}')
Remove-Item $sim -Recurse -Force
