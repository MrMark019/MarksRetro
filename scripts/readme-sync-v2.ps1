$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))

# 1) 复古章节:组件描述更新为 fork 版 + v2 编辑口
$old1 = '单机便携包(推荐交付形态):U盘根目录 RETRO-X86\ 是自包含文件夹'
$new1 = @(
'单机便携包 v2(推荐交付形态):U盘根目录 RETRO-X86\ 自包含文件夹,',
'配置入口统一为 retro.ini(base_url/model/max_tokens/context_window/密钥文件/历史',
'条数/审批开关,GBK 记事本直接编辑,改完跑 agent.bat 即生效);models.txt 编号',
'菜单支持 agent.bat 2 选模型,会话内 /model 名字 随时热切;密钥只存 key.txt,',
'经命令行 --key 传入,config.json 不落密钥。',
'本包内 micro-agent.exe 为 fork 增强版(官方原版备份为 micro-agent.exe.stock):',
'修复中文输入(GBK→UTF-8)与中文输出(UTF-8→GBK),XP 控制台中文问答完整可用;',
'新增 max_tokens/context_window 配置与 /model 命令。retro-install.bat(v2.4)',
'主流程同步以上全部行为,默认模型 qwen3.8-flash。',
'',
'单机便携包(推荐交付形态):U盘根目录 RETRO-X86\ 是自包含文件夹'
) -join "`r`n"
if ($t.Contains($old1) -and -not $t.Contains('retro.ini')) {
    $t = $t.Replace($old1, $new1)
}

# 2) 已知限制:中文显示限制已由 fork 解除
$old2 = @(
'已知限制:',
'  - 中文提问正常;但 v0.1.0 会把模型回复中的中文剥离成 ASCII(显示乱码),',
'    英文问答完整可用。后续升级 agent 可解。'
) -join "`r`n"
$new2 = @(
'已知限制:',
'  - 官方 v0.1.0 会把回复中文剥成 ASCII——本U盘已改用 fork 修复版解决',
'    (输入输出双向 GBK<->UTF-8 转换);若换回 stock 原版则恢复该限制。',
'  - context_window 为声明/显示项;历史长度控制用 max_history。'
) -join "`r`n"
if ($t.Contains($old2)) { $t = $t.Replace($old2, $new2) }

[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 主文档已同步 v2/fork 状态'
