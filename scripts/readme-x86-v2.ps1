$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dst = 'E:\RETRO-X86'
$gbk = [Text.Encoding]::GetEncoding(936)
Remove-Item "$dst\model.txt" -Force -ErrorAction SilentlyContinue

# ---------- 包内 README(v2) ----------
$readme = @(
'RETRO 单机 AI Agent 便携包 v2.0  (XP SP3 / 32 位 Windows 专用)',
'================================================================',
'',
'自包含文件夹:拷到任意位置都能用,不依赖大U盘其他内容。',
'防病毒做法:母盘留干净电脑,只拷本文件夹到一次性介质进毒区,用完即弃。',
'',
'★ 唯一配置入口:retro.ini(记事本直接改,改完跑 agent.bat 即生效)',
'    base_url        服务商接口地址(默认阿里云百炼兼容端点)',
'    model           默认模型名(默认 qwen3.8-flash)',
'    max_tokens      单次最大输出 token(0=不限)',
'    context_window  上下文窗口声明(/info 显示用)',
'    key_file        密钥所在文件(默认 key.txt,第一行 sk- 开头)',
'    max_history     对话历史条数(内存小可调低)',
'    require_approval 执行命令前是否人工确认',
'',
'文件:',
'  micro-agent.exe   agent 本体(本包为 fork 增强版:中文输入输出/ /model 切换)',
'  micro-agent.exe.stock  官方原版备份(想换回直接改名)',
'  retrobridge.exe   本机 TLS 桥(明文HTTP转HTTPS,XP 老TLS栈太旧才需要)',
'  ca-bundle.crt     根证书包',
'  models.txt        编号模型菜单(agent.bat 2 即用 2 号模型)',
'  key.txt           密钥唯一存放点  <-- 使用前把 sk- 密钥贴到第一行',
'  setup.bat         环境体检(时钟/二进制/密钥),不改任何东西',
'  agent.bat         日常入口:体检 -> 生成运行配置 -> 拉桥 -> 对话 -> 退出清理',
'',
'用法:',
'  1. 编辑 key.txt 贴入 sk- 密钥(可选:改 retro.ini / models.txt)',
'  2. 双击 agent.bat 开始;agent.bat 2 用菜单2号模型;会话里 /model 名字 随时切换',
'  3. /help 看命令,/clear 清历史,/quit 退出',
'',
'说明与限制:',
'  - Windows XP SP3+ 32位;机器自身能上网;密钥只在 key.txt,不进 config;',
'  - 中文输入输出已由 fork 修复(GBK<->UTF-8 自动转换);',
'  - 时钟错乱(CMOS 电池)会导致 TLS 失败,启动时自动检测并尝试 NTP 同步;',
'  - 换服务商:改 retro.ini 的 base_url 即可(需 OpenAI 兼容协议)。'
) -join "`r`n"
[IO.File]::WriteAllText("$dst\README.txt", ($readme + "`r`n"), $gbk)
'RETRO-X86 README v2 已写'
