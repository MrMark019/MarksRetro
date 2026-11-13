$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
$anchor = 'Q: Windows 双击 bat 闪退?'
$lines = @(
'Q: 老32位机器双击 bat 直接闪退,连 logs 都没有?',
'A: 启动器已全部改为纯 ASCII 批处理(老 cmd.exe 在 XP/未打补丁的 Win7 上',
'   解析 UTF-8+chcp 65001 的中文批处理会直接崩溃,这就是"闪退且零日志"的根因)。',
'   新版启动器还会:①无论U盘可否写,都在本机 %TEMP%\opencode-launcher.log 留面包屑;',
'   ②启动前检测 PowerShell——Win7 裸机自带 2.0,会明确提示需装 WMF 5.1(装完重启);',
'   ③XP/Server 2003 没有可用 PowerShell 且 Node 22 无法运行,属于无解机器,只能走',
'   "64位机器 serve / 手机热点"方案(见上文 32 位说明)。',
'   若新版仍闪退:Win+R 输入 cmd 回车,再敲:',
'     cmd /k "E:\一键安装Pi.bat"',
'   (E: 换成U盘盘符)——窗口不会关,把屏幕内容拍照发回即可定位。',
$anchor
)
$new = ($lines -join "`r`n")
if (-not $t.Contains($anchor)) { throw '锚文本未找到' }
$t = $t.Replace($anchor, $new)
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 已插入排查条目'
