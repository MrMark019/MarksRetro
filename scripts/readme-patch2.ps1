$ErrorActionPreference = 'Stop'
$f = 'E:\README.txt'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
$anchor = '   若新版仍闪退:Win+R 输入 cmd 回车,再敲:'
$ins = '   判据:launcher.log 里 ps="powershell.exe"(带引号无路径)= 该机 System32 下没有' + "`r`n" +
        '   PowerShell 目录,基本可断定 XP/2003 级(此类机器三重无解:无 PS5.1、Node22 需' + "`r`n" +
        '   Win8.1+、系统时钟常因主板电池失效停在出厂年导致 HTTPS 全挂,只能走 serve/手机);' + "`r`n" +
        '   面包屑现含 [OS] 版本行,ver 输出会直接记进 launcher.log。' + "`r`n" + $anchor
if (-not $t.Contains($anchor)) { throw 'anchor missing' }
$t = $t.Replace($anchor, $ins)
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
'README 判据已补'
