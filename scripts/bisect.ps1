$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 400
Start-Process 'C:\RETRO\retrobridge.exe' -ArgumentList '-listen','127.0.0.1:8787','-cacert','C:\RETRO\ca-bundle.crt' -WindowStyle Hidden
Start-Sleep -Seconds 2
$key = (Get-Content 'E:\key.txt')[2].Trim()
$hdr = @{ 'Content-Type' = 'application/json'; Authorization = "Bearer $key" }

function Ask([string]$name, $obj) {
    $json = $obj | ConvertTo-Json -Depth 12 -Compress
    $f = "$env:TEMP\opencode\askbody.json"
    [IO.File]::WriteAllText($f, $json, [Text.UTF8Encoding]::new($false))
    $resp = & curl.exe -s --noproxy '*' --max-time 60 -X POST http://127.0.0.1:8787/v1/chat/completions -H "Content-Type: application/json" -H "Authorization: Bearer $key" --data-binary "@$f"
    $short = if ($resp.Length -gt 160) { $resp.Substring(0,160) + '...' } else { $resp }
    Write-Host "[$name] => $short"
}

$msgs = @(@{role='system'; content='You are helpful.'}, @{role='user'; content='只回复两个字:成功'})

# A: 无 tools
Ask 'A 无tools' @{ model='qwen3-coder-flash'; messages=$msgs }

# B: tools 含空 properties(无 required)
$toolB = @(@{ type='function'; function=@{ name='t1'; description='desc'; parameters=@{ type='object'; properties=@{} } } })
Ask 'B 空properties' @{ model='qwen3-coder-flash'; messages=$msgs; tools=$toolB }

# C: tools 含空 properties + 空 required
$toolC = @(@{ type='function'; function=@{ name='t1'; description='desc'; parameters=@{ type='object'; properties=@{}; required=@() } } })
Ask 'C 空properties+空required' @{ model='qwen3-coder-flash'; messages=$msgs; tools=$toolC }

# D: tools 有实际参数
$toolD = @(@{ type='function'; function=@{ name='t1'; description='desc'; parameters=@{ type='object'; properties=@{ host=@{ type='string'; description='h' } }; required=@('host') } } })
Ask 'D 正常参数' @{ model='qwen3-coder-flash'; messages=$msgs; tools=$toolD }

Get-CimInstance Win32_Process -Filter "Name='retrobridge.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
