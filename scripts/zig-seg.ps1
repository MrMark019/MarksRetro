$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tmp = "$env:TEMP\opencode\zigbuild"

# 0) 停掉串行下载循环(只杀 zig-dl 相关 powershell,不动当前会话)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match 'zig-dl\.ps1'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "已停串行任务 PID $($_.ProcessId)" }
# 也停掉可能残留的 curl
Get-CimInstance Win32_Process -Filter "Name='curl.exe'" | Where-Object {
    $_.CommandLine -match 'zig-x86_64-windows'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "已停 curl PID $($_.ProcessId)" }
Start-Sleep -Milliseconds 500

# 1) 拿元数据
$idx = curl.exe -sSL --ssl-no-revoke -m 60 'https://ziglang.org/download/index.json' | Out-String
$j = $idx | ConvertFrom-Json
$z = $j.'0.15.2'.'x86_64-windows'
$url = $z.tarball
$total = [long]$z.size
$sha = $z.shasum
"total=$total sha=$sha"

# 2) 分 8 段并行
$N = 8
$seg = [math]::Ceiling($total / $N)
$segs = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [long]($i * $seg)
    $e = [long]([Math]::Min($total - 1, $s + $seg - 1))
    if ($s -ge $total) { break }
    $segs += @{ Start = $s; End = $e; File = "$tmp\seg$i.bin" }
}
$jobs = @()
foreach ($sg in $segs) {
    if ((Test-Path $sg.File) -and (Get-Item $sg.File).Length -eq ($sg.End - $sg.Start + 1)) {
        Write-Host "段 $($sg.File) 已完成,跳过"
        continue
    }
    $jobs += Start-Job -ArgumentList $url, $sg.File, "$($sg.Start)-$($sg.End)" -ScriptBlock {
        param($u, $f, $range)
        & curl.exe -s --ssl-no-revoke -m 1800 -r $range -o $f $u
    }
}
Write-Host "已启动 $($jobs.Count) 个分段任务"

# 3) 等待(最多 25 分钟),每分钟报进度
$deadline = (Get-Date).AddMinutes(25)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    $done = 0; $have = 0
    foreach ($sg in $segs) {
        $want = $sg.End - $sg.Start + 1
        $got = if (Test-Path $sg.File) { (Get-Item $sg.File).Length } else { 0 }
        if ($got -ge $want) { $done++ }
        $have += [Math]::Min($got, $want)
    }
    Write-Host ("进度: {0}/{1} 段完成, 共 {2:N1}MB / {3:N1}MB" -f $done, $segs.Count, ($have/1MB), ($total/1MB))
    if ($done -eq $segs.Count) { break }
    if (Get-Job | Where-Object { $_.State -eq 'Failed' } ) { Write-Host '有分段任务失败,继续等其它段' }
}

# 4) 合并
$allDone = $true
foreach ($sg in $segs) {
    $want = $sg.End - $sg.Start + 1
    if (-not (Test-Path $sg.File) -or (Get-Item $sg.File).Length -lt $want) { $allDone = $false; Write-Host ("段不完整: " + $sg.File) }
}
if (-not $allDone) { Write-Host 'FAIL: 分段未齐'; exit 1 }
$out = "$tmp\zig.zip"
$fs = [IO.File]::Create($out)
foreach ($sg in $segs) {
    $bytes = [IO.File]::ReadAllBytes($sg.File)
    $fs.Write($bytes, 0, $bytes.Length)
}
$fs.Close()
Write-Host ("合并完成: " + [math]::Round((Get-Item $out).Length/1MB,1) + "MB")

# 5) 校验
$got = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
Write-Host "sha got=$got want=$sha"
if ($got -ne $sha.ToLower()) { Write-Host 'FAIL: 哈希不符'; exit 1 }
Write-Host 'ZIP 完整 ✓'
Remove-Item "$tmp\zx" -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $out "$tmp\zx" -Force
$zigExe = Get-ChildItem "$tmp\zx" -Recurse -Filter zig.exe | Select-Object -First 1
& $zigExe.FullName version
$zigExe.FullName | Out-File "$tmp\zigpath.txt" -Encoding ascii
Write-Host 'ZIG READY'
