$ErrorActionPreference = 'Stop'
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
if ($t.Contains('【复古路线】')) { "已存在,跳过"; exit 0 }
$anchor = "--------------------------------`r`n常见问题"
if (-not $t.Contains($anchor)) { throw 'anchor missing' }
$sec = @(
'--------------------------------',
'【复古路线】XP / Vista / Win7 / Win8 老机器接入在线 API',
'--------------------------------',
'适用: Windows 版本低于 10(Pi / OpenCode 都要求 Win10+)。',
'组件: micro-agent(retro-agent 项目,MIT,Zig 单文件 762KB,XP SP3 /',
'      Pentium III+ / 64MB 内存即可)。它只走明文 HTTP,HTTPS 由"中继"',
'      完成 —— 老机器上不装任何 TLS 组件,彻底绕开 XP 的 TLS 1.0 死穴。',
'',
'步骤:',
'  1. 中继机(任意现代 Windows):双击U盘 opencode\retro\relay\relay-start.bat',
'     (右键管理员运行,否则只监听 127.0.0.1)。默认转发到阿里云百炼兼容端点;',
'     换上游: relay-start.bat -Upstream https://某主机/v1 -Port 8787',
'  2. U盘 opencode\retro\base-url.txt 填中继地址,如 http://192.168.1.100:8787',
'     opencode\retro\model.txt 填模型名(默认 qwen3-coder-flash)',
'     key.txt 第三行放 sk- 密钥(与 Pi 同一约定)',
'  3. 老机器双击 一键安装.bat(自动识别老系统转装 RETRO),',
'     或直接双击 retro-install.bat —— 纯批处理,无需 PowerShell,XP 可用',
'  4. 老机器运行 C:\RETRO\agent.bat 开始对话',
'',
'手机热点形态: 手机开热点、老机器连接,Termux 里跑同类反代',
'(如 caddy: reverse_proxy :8787 https://dashscope.aliyuncs.com/compatible-mode/v1),',
'base-url.txt 填 http://192.168.43.1:8787,全程不需要现场网络。',
'',
'限制: micro-agent 内置工具偏系统诊断/命令执行(带白名单/审批),重度写码',
'      建议在中继机/现代机上跑完整 agent;v0.1.0 的 --mode api 为占位,',
'      日常使用交互界面。中继访问日志: %TEMP%\opencode-relay.log。',
'',
$anchor
)
$t = $t.Replace($anchor, (($sec -join "`r`n")))
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 复古路线章节已插入'
