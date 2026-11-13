$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))

# 1) U盘清单加一行
$a1 = '  logs\                                           安装日志目录(运行后自动生成)'
if ($t.Contains($a1) -and -not $t.Contains('RETRO-X86')) {
    $t = $t.Replace($a1, $a1 + "`r`n" + '  RETRO-X86\                                      复古方案自包含便携包(7MB,可单独拷走,见复古路线章节)')
    '清单已加 RETRO-X86'
}

# 2) 复古章节尾部加"单机便携包/防病毒"说明
$a2 = '备用(可选):多台老机器共用出口/老机器省资源时,可把 TLS 中继放到旁边的'
if ($t.Contains($a2) -and -not $t.Contains('单机便携包')) {
    $add = @(
    '单机便携包(推荐交付形态):U盘根目录 RETRO-X86\ 是自包含文件夹',
    '(micro-agent + TLS 桥 + 证书 + setup.bat/agent.bat + 占位 key.txt),',
    '不依赖U盘其他内容。防病毒做法:母盘留干净机,只拷 RETRO-X86 到一次性介质',
    '进毒区;到目标机后编辑 key.txt 贴密钥 -> setup.bat -> agent.bat 对话。',
    '毒区用完即弃,勿拷回;注意 config.json 内含明文密钥。',
    '',
    $a2
    ) -join "`r`n"
    $t = $t.Replace($a2, $add)
    '复古章节已补便携包说明'
}
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
