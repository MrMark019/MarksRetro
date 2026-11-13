$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function To-CrlfNoBom([string]$src, [string]$dstDir, [string]$dstName) {
    $text = [System.IO.File]::ReadAllText($src, [System.Text.UTF8Encoding]::new($false))
    $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
    $dst = Join-Path $dstDir $dstName
    [System.IO.File]::WriteAllText($dst, $text, [System.Text.UTF8Encoding]::new($false))
    "OK $dst"
}

$tmp = "$env:TEMP\opencode"
New-Item -ItemType Directory 'E:\opencode\retro\relay' -Force | Out-Null
To-CrlfNoBom "$tmp\api-relay.ps1"   'E:\opencode\retro\relay' 'api-relay.ps1'
To-CrlfNoBom "$tmp\relay-start.bat" 'E:\opencode\retro\relay' 'relay-start.bat'
To-CrlfNoBom "$tmp\retro-install.bat" 'E:\' 'retro-install.bat'
To-CrlfNoBom "$tmp\base-url.txt" 'E:\opencode\retro' 'base-url.txt'
To-CrlfNoBom "$tmp\model.txt"    'E:\opencode\retro' 'model.txt'

# --- triage hook into 一键安装.bat ---
$f = 'E:\一键安装.bat'
$t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
if ($t.Contains('RETRO installer')) { "triage hook already present"; exit 0 }
$t = $t.Replace("rem ==================================================================`r`nsetlocal`r`n", "rem ==================================================================`r`nsetlocal enabledelayedexpansion`r`n")
if (-not $t.Contains('setlocal enabledelayedexpansion')) { throw 'setlocal anchor failed' }
$anchor = 'rem --- gate 1: PowerShell must exist ---'
if (-not $t.Contains($anchor)) { throw 'gate1 anchor missing' }
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
"triage hook inserted into 一键安装.bat"
$b = [System.IO.File]::ReadAllBytes($f)
"非ASCII字节: " + (@($b | Where-Object { $_ -gt 127 }).Count)
