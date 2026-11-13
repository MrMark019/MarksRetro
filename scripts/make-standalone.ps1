$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dst = 'E:\RETRO-X86'
New-Item -ItemType Directory $dst -Force | Out-Null

# 二进制
Copy-Item 'E:\opencode\retro\micro-agent.exe' "$dst\micro-agent.exe" -Force
Copy-Item 'E:\opencode\retro\retrobridge.exe' "$dst\retrobridge.exe" -Force
Copy-Item 'E:\opencode\retro\ca-bundle.crt'   "$dst\ca-bundle.crt"   -Force

# bat:CRLF + 纯 ASCII 校验
foreach ($n in 'setup.bat','agent.bat') {
    $text = [System.IO.File]::ReadAllText("$env:TEMP\opencode\standalone\$n", [System.Text.UTF8Encoding]::new($false))
    $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText("$dst\$n", $text, [System.Text.UTF8Encoding]::new($false))
    $b = [System.IO.File]::ReadAllBytes("$dst\$n")
    $na = @($b | Where-Object { $_ -gt 127 }).Count
    if ($na -gt 0) { throw "$n 含非 ASCII 字节 $na" }
    "$n OK (ASCII, CRLF)"
}

# key.txt 占位(母盘绝不含真实密钥)
[IO.File]::WriteAllText("$dst\key.txt", "sk-在这里粘贴你的API密钥替换本行`r`n", [Text.Encoding]::GetEncoding(936))
'qwen3-coder-flash' | Out-File "$dst\model.txt" -Encoding ascii

# README(GBK,XP 记事本友好)
$readme = @(
'RETRO 单机 AI Agent 便携包 v1.0  (XP SP3 / 32 位 Windows 专用)',
'================================================================',
'',
'这个文件夹是自包含的:拷到任意位置(U盘/硬盘/一次性小盘)都能用,',
'不依赖大U盘上的其他文件。推荐做法:母盘留在干净电脑,只把本文件夹',
'拷到去"毒区"的介质上(约 7MB)。',
'',
'文件说明:',
'  micro-agent.exe   AI 终端 agent(官方 XP 构建,762KB)',
'  retrobridge.exe   本机 TLS 桥(自带 TLS1.2+证书,XP 系统 TLS 太旧才需要它)',
'  ca-bundle.crt     根证书包(桥使用)',
'  key.txt           把 API 密钥(sk- 开头)粘贴到第一行  <-- 唯一要改的文件',
'  model.txt         模型名,默认 qwen3-coder-flash(按你的服务商改)',
'  setup.bat         第一步:体检环境(时钟/二进制)并生成 config.json',
'  agent.bat         第二步:开始对话(自动拉起 TLS 桥,退出自动清理)',
'',
'使用(每台新机器只做一次 setup):',
'  1. 编辑 key.txt,粘贴 sk- 密钥',
'  2. 双击 setup.bat,看到 Setup complete 即可',
'  3. 双击 agent.bat 对话;退出后想再用,直接双击 agent.bat',
'',
'要求与说明:',
'  - Windows XP SP3 或更高 32 位 Windows;机器自身能上网(网线/WiFi);',
'  - 默认对接阿里云百炼兼容端点(https://dashscope.aliyuncs.com/compatible-mode);',
'    换服务商:新建 base-url.txt 写 https://某主机/前缀 再跑 setup.bat;',
'  - 时钟错乱(CMOS 电池失效)会导致 TLS 失败,setup/agent 都会自动检测并',
'    尝试 NTP 同步,同步不了会明确提示,换电池根治;',
'  - 中文提问正常;agent v0.1.0 对回复中的中文显示受限(英文完整);',
'  - 防病毒:本文件夹进毒区后,不要再拷回干净电脑,用完即弃;',
'    config.json 含明文密钥,注意介质保管。'
) -join "`r`n"
[IO.File]::WriteAllText("$dst\README.txt", $readme, [Text.Encoding]::GetEncoding(936))
'README.txt 已写(GBK)'

Write-Host '=== 文件夹终态 ==='
Get-ChildItem $dst | ForEach-Object { '{0,-18} {1,8:N1}KB' -f $_.Name, ($_.Length/1KB) }
