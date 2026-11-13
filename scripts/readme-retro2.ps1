$ErrorActionPreference = 'Stop'
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))

$startMark = '--------------------------------' + "`r`n" + '【复古路线】'
$endMark = '--------------------------------' + "`r`n" + '常见问题'
$si = $t.IndexOf($startMark)
$ei = $t.IndexOf($endMark)
if ($si -lt 0 -or $ei -lt 0 -or $ei -le $si) { throw "找不到章节边界 si=$si ei=$ei" }

$lines = @(
'--------------------------------',
'【复古路线】XP / Vista / Win7 / Win8 老机器接入在线 API(单机)',
'--------------------------------',
'适用: Windows 版本低于 10(Pi / OpenCode 都要求 Win10+)。',
'组件:',
'  micro-agent  Retro Agent v0.1.0(Zig 单文件 762KB,XP SP3 / Pentium III+ /',
'               64MB 内存即可,MIT)。它只说明文 HTTP,自身不带 TLS。',
'  retrobridge  本机 TLS 桥(Go 1.10 构建,5.5MB,自带 TLS1.2 与 CA 证书包,',
'               监听 127.0.0.1:8787,把明文请求转发到阿里云百炼 HTTPS)。',
'  全程老机器单机自足:不需要第二台设备、不需要内网穿透、不需要热点。',
'',
'使用:',
'  1. U盘 key.txt 第三行放 sk- 密钥;model.txt 填模型名(默认 qwen3-coder-flash)',
'  2. 老机器双击 一键安装.bat(检测到老系统自动转装 RETRO),',
'     或直接双击 retro-install.bat(纯批处理,无需 PowerShell)',
'  3. 运行 C:\RETRO\agent.bat:自动拉起 TLS 桥 -> 进入对话 -> 退出自动清理',
'  唯一网络要求:老机器自身能上网(插网线或已连 WiFi)。',
'',
'已知限制:',
'  - 中文提问正常;但 v0.1.0 会把模型回复中的中文剥离成 ASCII(显示乱码),',
'    英文问答完整可用。后续升级 agent 可解。',
'  - 换服务商:retrobridge.exe -upstream https://某主机/某前缀 即可',
'    (micro-agent 固定请求 /v1/chat/completions,桥会自动防止重复 /v1)。',
'  - 排障:retrobridge.exe -listen 127.0.0.1:8787 -cacert ca-bundle.crt -debug',
'    会打印请求头与 body 取证信息。',
'',
'备用(可选):多台老机器共用出口/老机器省资源时,可把 TLS 中继放到旁边的',
'  64 位机器:双击U盘 opencode\retro\relay\relay-start.bat(管理员运行),',
'  再把 base-url.txt 改为 http://<该机器IP>:8787 重装即可。',
''
)
$newSec = ($lines -join "`r`n") + "`r`n"
$t = $t.Substring(0, $si) + $newSec + $t.Substring($ei)
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 复古章节已重写为单机版'
