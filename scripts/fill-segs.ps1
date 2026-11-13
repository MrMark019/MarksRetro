$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tmp = "$env:TEMP\opencode\zigbuild"
$total = 92614574
$N = 8
$seg = [math]::Ceiling($total / $N)
$url = 'https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip'

for ($i = 0; $i -lt $N; $i++) {
    $s = [long]($i * $seg)
    $e = [long]([Math]::Min($total - 1, $s + $seg - 1))
    $want = $e - $s + 1
    $file = "$tmp\seg$i.bin"
    $have = if (Test-Path $file) { (Get-Item $file).Length } else { 0 }
    if ($have -ge $want) { continue }
    Write-Host "seg$i 缺 $($want-$have)B,补下 range $($s+$have)-$e ..."
    $part = "$file.patch"
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    & curl.exe -s --ssl-no-revoke -m 300 -r "$($s+$have)-$e" -o $part $url
    if ((Test-Path $part) -and (Get-Item $part).Length -eq ($want - $have)) {
        $fs = [IO.File]::Open($file, [IO.FileMode]::Append)
        $bytes = [IO.File]::ReadAllBytes($part)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
        Remove-Item $part -Force
        Write-Host "  seg$i 补齐 ✓ (现 $((Get-Item $file).Length)B)"
    } else {
        Write-Host "  seg$i 补下失败(得到 $((Get-Item $part -ErrorAction SilentlyContinue).Length)B,期望 $($want-$have)B)"
    }
}
$tot = 0
for ($i = 0; $i -lt $N; $i++) { $tot += (Get-Item "$tmp\seg$i.bin" -ErrorAction SilentlyContinue).Length }
"当前总字节: $tot / $total"
