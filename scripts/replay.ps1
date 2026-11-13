$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = "$env:TEMP\opencode\bridge-e3.log"
$line = (Select-String -Path $log -Pattern 'DEBUG body\(4695B\): ' | Select-Object -First 1).Line
$json = $line.Substring($line.IndexOf('DEBUG body(4695B): ') + 'DEBUG body(4695B): '.Length)
Write-Host "提取 body 长度: $($json.Length)"
$obj = $json | ConvertFrom-Json
Write-Host "JSON 解析: OK, tools=$($obj.tools.Count)"

Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt' -WindowStyle Hidden
Start-Sleep -Seconds 2
$key = (Get-Content 'E:\key.txt')[2].Trim()
function Post($o, [string]$tag) {
    $f = "$env:TEMP\opencode\replay.json"
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
    $r = & curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" --data-binary "@$f" http://127.0.0.1:8787/v1/chat/completions
    $s = if ($r.Length -gt 130) { $r.Substring(0,130) } else { $r }
    Write-Host "[$tag] $s"
}

Post $obj '原始完整体'
# 变体0:不重新序列化,原样字节回放
$f0 = "$env:TEMP\opencode\replay0.json"
[IO.File]::WriteAllText($f0, $json, [Text.UTF8Encoding]::new($false))
$r0 = & curl.exe -s --noproxy '*' --max-time 60 -H 'Content-Type: application/json' -H "Authorization: Bearer $key" --data-binary "@$f0" http://127.0.0.1:8787/v1/chat/completions
$s0 = if ($r0.Length -gt 130) { $r0.Substring(0,130) } else { $r0 }
Write-Host "[原字节回放] $s0"
# 变体1:去掉 enum(alert 工具)
$o2 = $json | ConvertFrom-Json
foreach ($t in $o2.tools) {
    $props = $t.function.parameters.properties
    if ($props) { foreach ($pk in @($props.PSObject.Properties)) { if ($pk.Value.PSObject.Properties.Name -contains 'enum') { $pk.Value.PSObject.Properties.Remove('enum') } } }
}
Post $o2 '去enum'
# 变体2:去掉 default
$o3 = $json | ConvertFrom-Json
foreach ($t in $o3.tools) {
    $props = $t.function.parameters.properties
    if ($props) { foreach ($pk in @($props.PSObject.Properties)) { if ($pk.Value.PSObject.Properties.Name -contains 'default') { $pk.Value.PSObject.Properties.Remove('default') } } }
}
Post $o3 '去default'
# 变体3:两者都去
$o4 = $json | ConvertFrom-Json
foreach ($t in $o4.tools) {
    $props = $t.function.parameters.properties
    if ($props) { foreach ($pk in @($props.PSObject.Properties)) { foreach ($p in 'enum','default') { if ($pk.Value.PSObject.Properties.Name -contains $p) { $pk.Value.PSObject.Properties.Remove($p) } } } }
}
Post $o4 '去enum+default'
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
