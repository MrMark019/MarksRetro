$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- 1) U盘全量备份 ----------
$dst = 'D:\usb-master-20261111-fork'
Write-Host "=== U盘全量 -> $dst ==="
& robocopy E:\ $dst /E /NFL /NDL /NJH /NP /R:1 /W:1 /XD 'E:\$RECYCLE.BIN' 'E:\System Volume Information' "$dst" | Select-Object -Last 5
Write-Host "robocopy exit=$LASTEXITCODE (<8 成功)"
$sz = (Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host ("备份大小: {0:N2} GB" -f ($sz/1GB))

# ---------- 2) fork 源码树 + 构建工具备份 ----------
$sdst = 'D:\retro-fork-src-20261111'
Write-Host "=== fork 源码 -> $sdst ==="
New-Item -ItemType Directory $sdst -Force | Out-Null
$src = "$env:TEMP\opencode\zigbuild\retro-agent"
# 源码+构建输出(排除 .zig-cache 缓存)
& robocopy $src "$sdst\retro-agent" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XD .zig-cache | Out-Null
Write-Host ("retro-agent 源码+产物 exit=$LASTEXITCODE")
# 原始树(对照 diff 用)
& robocopy "$env:TEMP\opencode\zigbuild\retro-pristine" "$sdst\retro-pristine" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XD .zig-cache | Out-Null
Write-Host ("pristine 对照树 exit=$LASTEXITCODE")
# 关键脚本(下载分段器/补丁测试/打包生成器)
$tmp = "$env:TEMP\opencode"
New-Item -ItemType Directory "$sdst\scripts" -Force | Out-Null
foreach ($s in 'zig-dl.ps1','zig-seg.ps1','fill-segs.ps1','fork-test.ps1','fork-test2.ps1','fork-test3.ps1','make-x86-v2.ps1','readme-x86-v2.ps1','readme-sync-v2.ps1','final-xp-sim.ps1') {
    if (Test-Path "$tmp\$s") { Copy-Item "$tmp\$s" "$sdst\scripts\" -Force }
}
# 已编译好的 fork 二进制 + 桥源码
Copy-Item "$src\zig-out\bin\agentxp.exe" "$sdst\micro-agent-fork.exe" -Force
Copy-Item "$tmp\bridge\main.go" "$sdst\retrobridge-src.go" -Force
Copy-Item "$tmp\bridge\retrobridge.exe" "$sdst\retrobridge.exe" -Force
Write-Host '=== 备份清单 ==='
Get-ChildItem $sdst | ForEach-Object { '{0,-28} {1}' -f $_.Name, $(if ($_.PSIsContainer) {'<dir>'} else {"$([math]::Round($_.Length/1KB))KB"}) }
Write-Host ("fork源码备份大小: {0:N1} MB" -f ((Get-ChildItem $sdst -Recurse -File | Measure-Object Length -Sum).Sum/1MB))
Write-Host '=== 校验抽查:备份里的 fork 二进制可运行 ==='
& "$sdst\micro-agent-fork.exe" --version
