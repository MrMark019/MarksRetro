$ErrorActionPreference = 'Stop'
$f = 'E:\一键安装.bat'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
if ($t.Contains('RETRO installer')) { "已注入,跳过"; exit 0 }

$t2 = $t.Replace("`r`nsetlocal`r`n", "`r`nsetlocal enabledelayedexpansion`r`n")
if ($t2 -eq $t) { throw 'setlocal anchor failed' }
$t = $t2

$anchor = '"%PS%" -NoProfile -Command "exit 0" >nul 2>nul'
if (-not $t.Contains($anchor)) { throw 'gate anchor missing' }
$hookLines = @(
'rem --- legacy OS triage: Pi/OpenCode need Windows 10+; older Windows goes RETRO ---',
'set "CV="',
'for /f "tokens=3" %%v in (''reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentVersion 2^>nul ^| find "CurrentVersion"'') do set "CV=%%v"',
'if defined CV (',
'    for /f "tokens=1 delims=." %%m in ("!CV!") do set "CVMAJ=%%m"',
'    if !CVMAJ! LSS 10 (',
'        echo [NOTICE] Legacy Windows detected, CurrentVersion !CV!. Pi/OpenCode need Windows 10+.',
'        echo [NOTICE] Handing over to RETRO installer (micro-agent for legacy Windows)...',
'        echo.',
'        call "%~dp0retro-install.bat"',
'        exit /b !ERRORLEVEL!',
'    )',
')',
'',
''
)
$hook = ($hookLines -join "`r`n")
$t = $t.Replace($anchor, $hook + $anchor)
[System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($false))
"triage hook 已注入"
$b = [System.IO.File]::ReadAllBytes($f)
"非ASCII字节: " + (@($b | Where-Object { $_ -gt 127 }).Count)
