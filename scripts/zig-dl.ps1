$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tmp = "$env:TEMP\opencode\zigbuild"
$zip = "$tmp\zig.zip"
$wantSize = 92585472  # 88.3MB,以 index.json 为准下面会重查
# 期望大小与 sha256 从官方 index 取
$idx = curl.exe -sSL --ssl-no-revoke -m 60 'https://ziglang.org/download/index.json' | Out-String
$j = $idx | ConvertFrom-Json
$z = $j.'0.15.2'.'x86_64-windows'
$wantSize = [long]$z.size
$wantSha = $z.shasum
Write-Host "目标: $([math]::Round($wantSize/1MB,1))MB sha256=$wantSha"
$urls = @(
  $z.tarball,
  'https://github.com/ziglang/zig/releases/download/0.15.2/zig-x86_64-windows-0.15.2.zip'
)
# 清掉坏头
if ((Test-Path $zip) -and ((Get-Item $zip).Length -ne $wantSize)) { }
$ok = $false
for ($round = 1; $round -le 30 -and -not $ok; $round++) {
    $url = $urls[($round - 1) % $urls.Count]
    $have = if (Test-Path $zip) { (Get-Item $zip).Length } else { 0 }
    if ($have -ge $wantSize) { break }
    Write-Host "round $round : $url (已有 $([math]::Round($have/1MB,1))MB)"
    if ($have -eq 0) {
        curl.exe -sSL --ssl-no-revoke -m 420 -o $zip $url 2>&1 | Out-Null
    } else {
        curl.exe -sSL --ssl-no-revoke -m 420 -C $have -o $zip $url 2>&1 | Out-Null
    }
    $now = if (Test-Path $zip) { (Get-Item $zip).Length } else { 0 }
    Write-Host "  -> $([math]::Round($now/1MB,1))MB"
    if ($now -ge $wantSize) { break }
    Start-Sleep -Seconds 3
}
if (-not (Test-Path $zip)) { Write-Host 'FAIL: 无文件'; exit 1 }
$len = (Get-Item $zip).Length
if ($len -lt $wantSize) { Write-Host "FAIL: 不完整 $len/$wantSize"; exit 1 }
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Write-Host "sha256 got=$got want=$wantSha"
if ($wantSha -and $got -ne $wantSha.ToLower()) { Write-Host 'FAIL: 哈希不符'; Remove-Item $zip -Force; exit 1 }
Write-Host 'ZIP 完整,解压...'
Remove-Item "$tmp\zx" -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip "$tmp\zx" -Force
$zigExe = Get-ChildItem "$tmp\zx" -Recurse -Filter zig.exe | Select-Object -First 1
& $zigExe.FullName version
$zigExe.FullName | Out-File "$tmp\zigpath.txt" -Encoding ascii
Write-Host 'ZIG READY'
