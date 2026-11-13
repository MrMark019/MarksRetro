$ErrorActionPreference = 'Stop'
foreach ($f in @('E:\一键安装.bat', 'E:\一键安装Pi.bat')) {
    $t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
    $anchor = 'if exist "%~dp0logs" >>"%~dp0logs\launcher.log" echo [%DATE% %TIME%] start %~nx0 user=%USERNAME% host=%COMPUTERNAME% ps="%PS%" 2>nul'
    if (-not $t.Contains($anchor)) { throw "anchor missing in $f" }
    if ($t.Contains('ver >>')) { "已有 ver,跳过 $f"; continue }
    $add = $anchor + "`r`n" + 'if exist "%~dp0logs" (echo [OS^] & ver >>"%~dp0logs\launcher.log" 2>nul)'
    $t = $t.Replace($anchor, $add)
    [System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
    "已插入 ver 捕获: $f"
}
# 纯 ASCII 复核
foreach ($f in @('E:\一键安装.bat', 'E:\一键安装Pi.bat')) {
    $b = [System.IO.File]::ReadAllBytes($f)
    $na = @($b | Where-Object { $_ -gt 127 }).Count
    "{0} 非ASCII={1}" -f (Split-Path $f -Leaf), $na
}
