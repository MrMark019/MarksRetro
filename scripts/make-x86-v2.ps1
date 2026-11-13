$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dst = 'E:\RETRO-X86'
$gbk = [Text.Encoding]::GetEncoding(936)

# ---------- retro.ini (GBK, 唯一编辑入口) ----------
$ini = @(
'; ================================================================',
';   RETRO 配置文件 —— 唯一编辑入口,改完直接跑 agent.bat 即生效',
';   (本文件是 ANSI/GBK 编码,用记事本编辑即可)',
'; ================================================================',
'',
'; 上游服务商地址:本机 TLS 桥要转发的目标(OpenAI 兼容 HTTPS 端点,不带 /v1 后缀)。',
'; 换服务商就改这一行,例如 https://api.xx.com/v1 之类。',
'upstream=https://dashscope.aliyuncs.com/compatible-mode',
'',
'; 本机 TLS 桥监听端口(微智能体连这里,一般不用改)。',
'port=8787',
'',
'; 默认模型名(必须与服务商目录里的名字完全一致)。',
'; 会话中也可以随时 /model 名字 切换,或 agent.bat 数字 选下面的菜单。',
'model=qwen3.8-flash',
'',
'; 单次回复最大输出 token(0=不限制,由服务商默认)',
'max_tokens=8192',
'',
'; 模型上下文窗口(token,用于 /info 显示;0=不声明)',
'context_window=131072',
'',
'; 密钥文件:第一行放 sk- 开头的 API Key。密钥只存这里,',
'; agent 启动时经命令行传给程序,不写进 config.json。',
'key_file=key.txt',
'',
'; 对话历史滑动窗口条数(老机器内存小可以调低,如 40)',
'max_history=100',
'',
'; 执行系统命令前是否要求人工确认(true/false)',
'require_approval=false'
) -join "`r`n"
[IO.File]::WriteAllText("$dst\retro.ini", ($ini + "`r`n"), $gbk)

# ---------- models.txt (编号菜单) ----------
$menu = @(
'; agent.bat 2 就用编号 2 的模型(编号后仍可带其它参数透传)',
'1=qwen3.8-flash',
'2=deepseek-v4.1-flash',
'3=qwen3.8-max',
'4=qwen3-vl-plus'
) -join "`r`n"
[IO.File]::WriteAllText("$dst\models.txt", ($menu + "`r`n"), $gbk)

# ---------- key.txt 占位 ----------
if (-not (Test-Path "$dst\key.txt") -or ((Get-Content "$dst\key.txt" -Encoding Default -Raw) -match '粘贴')) {
    [IO.File]::WriteAllText("$dst\key.txt", "sk-在这里粘贴你的API密钥替换本行`r`n", $gbk)
}

# ---------- agent.bat (ASCII, CRLF) ----------
$agent = @'
@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"

rem ---------- clock guard ----------
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [WARN] System clock wrong. Trying NTP sync...
net time /setsntp:ntp.aliyun.com >nul 2>nul
w32tm /resync /force >nul 2>nul
"%DIR%retrobridge.exe" -check >nul 2>nul
if not errorlevel 3 goto c_ok
echo [ERROR] Clock still wrong - TLS cert checks WILL fail.
echo         Fix date/time manually, or replace the CMOS battery.
pause
exit /b 7
:c_ok

rem ---------- parse retro.ini ----------
set MODEL=
set UPSTREAM=
set BRIDGEPORT=8787
set KEYFILE=key.txt
set MAXTOK=0
set CTXW=0
set MAXHIST=100
set APPROVE=false
for /f "usebackq eol=; tokens=1,* delims==" %%k in ("%DIR%retro.ini") do (
    set "K=%%k"
    set "V=%%l"
    if /i "!K!"=="model" set MODEL=!V!
    if /i "!K!"=="upstream" set UPSTREAM=!V!
    if /i "!K!"=="port" set BRIDGEPORT=!V!
    if /i "!K!"=="key_file" set KEYFILE=!V!
    if /i "!K!"=="max_tokens" set MAXTOK=!V!
    if /i "!K!"=="context_window" set CTXW=!V!
    if /i "!K!"=="max_history" set MAXHIST=!V!
    if /i "!K!"=="require_approval" set APPROVE=!V!
)
if not defined UPSTREAM set UPSTREAM=https://dashscope.aliyuncs.com/compatible-mode
if not defined MODEL set MODEL=qwen3.8-flash
if not defined MAXTOK set MAXTOK=0
if not defined CTXW set CTXW=0
if not defined MAXHIST set MAXHIST=100
set "BASEURL=http://127.0.0.1:%BRIDGEPORT%"

rem ---------- numbered model from models.txt:  agent.bat 2 ----------
set PICK=%~1
set SHIFT=
if defined PICK (
    echo %PICK%| findstr /r "^[0-9][0-9]*$" >nul && (
        for /f "usebackq eol=; tokens=1,* delims==" %%a in ("%DIR%models.txt") do (
            if "%%a"=="%PICK%" set MODEL=%%b
        )
        set SHIFT=1
    )
)

rem ---------- api key from key_file (never stored into config.json) ----------
set APIKEY=
if exist "%DIR%%KEYFILE%" (
    for /f "usebackq delims=" %%k in ("%DIR%%KEYFILE%") do (
        if not defined APIKEY (echo %%k| findstr /b "sk-" >nul && set "APIKEY=%%k")
    )
)
if not defined APIKEY (
    echo [ERROR] No valid sk- key found in %KEYFILE% ^(first line^).
    pause
    exit /b 2
)

rem ---------- runtime config (no secret inside) ----------
> "%DIR%config.json" (
    echo {
    echo   "agent": {
    echo     "name": "micro-agent",
    echo     "mode": "interactive",
    echo     "system_prompt": "You are an AI assistant for this machine. Use your tools to help with files, commands and diagnostics. Reply in the same language the user writes in.",
    echo     "max_history": %MAXHIST%
    echo   },
    echo   "transport": {
    echo     "api": {
    echo       "provider": "openai",
    echo       "api_key": "",
    echo       "model": "%MODEL%",
    echo       "base_url": "%BASEURL%",
    echo       "max_tokens": %MAXTOK%,
    echo       "context_window": %CTXW%
    echo     }
    echo   },
    echo   "security": {
    echo     "require_approval": %APPROVE%,
    echo     "max_exec_timeout_ms": 30000
    echo   },
    echo   "debug_mode": false
    echo }
)

echo   model: %MODEL%   endpoint: %BASEURL%
echo.

rem ---------- bridge lifecycle ----------
tasklist /fi "imagename eq retrobridge.exe" 2>nul | find /i "retrobridge.exe" >nul 2>nul
if errorlevel 1 (
    start "" /min "%DIR%retrobridge.exe" -listen 127.0.0.1:%BRIDGEPORT% -upstream "%UPSTREAM%" -cacert "%DIR%ca-bundle.crt"
    ping -n 4 127.0.0.1 >nul
)
if defined SHIFT (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %2 %3 %4 %5
) else (
    "%DIR%micro-agent.exe" --config "%DIR%config.json" --key "%APIKEY%" %*
)
taskkill /f /im retrobridge.exe >nul 2>nul
tskill retrobridge >nul 2>nul
'@
$agent = $agent -replace "`r`n", "`n" -replace "`n", "`r`n"
$b = [Text.Encoding]::ASCII.GetBytes($agent)
if (@($b | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'agent.bat not ASCII' }
[IO.File]::WriteAllBytes("$dst\agent.bat", $b)

# ---------- setup.bat (ASCII, CRLF) ----------
$setup = @'
@echo off
setlocal enabledelayedexpansion
set "DIR=%~dp0"
echo.
echo ============================================
echo   RETRO standalone setup v2 (check only)
echo ============================================
echo.

"%DIR%retrobridge.exe" -check >nul 2>nul
if errorlevel 3 (
    echo [WARN] System clock wrong. Trying NTP sync...
    net time /setsntp:ntp.aliyun.com >nul 2>nul
    w32tm /resync /force >nul 2>nul
    "%DIR%retrobridge.exe" -check >nul 2>nul
    if errorlevel 3 (echo [ERROR] Clock still wrong - fix it first ^(taskbar clock or CMOS battery^). & pause & exit /b 7)
)
echo [OK] Clock fine

"%DIR%micro-agent.exe" --version >nul 2>nul
if errorlevel 1 (echo [ERROR] micro-agent.exe cannot run here. & pause & exit /b 1)
echo [OK] micro-agent runs
echo.

if not exist "%DIR%retro.ini" (echo [ERROR] retro.ini missing. & pause & exit /b 2)
set KEYFILE=key.txt
for /f "usebackq eol=; tokens=1,* delims==" %%k in ("%DIR%retro.ini") do (
    set "K=%%k"
    if /i "!K!"=="key_file" set KEYFILE=%%l
    if /i "!K!"=="model" set MODEL=%%l
    if /i "!K!"=="upstream" set UPSTREAM=%%l
    if /i "!K!"=="port" set PORT=%%l
)
if not defined UPSTREAM set UPSTREAM=https://dashscope.aliyuncs.com/compatible-mode
if not defined PORT set PORT=8787
set APIKEY=
if exist "%DIR%%KEYFILE%" (
    for /f "usebackq delims=" %%k in ("%DIR%%KEYFILE%") do (
        if not defined APIKEY (echo %%k| findstr /b "sk-" >nul && set "APIKEY=%%k")
    )
)
if not defined APIKEY (
    echo [WARN] No sk- key yet. Edit %KEYFILE% first line, then run agent.bat.
) else (
    echo [OK] Key present: !APIKEY:~0,7!***
)
echo   model    : %MODEL%
echo   upstream : %UPSTREAM%
echo   bridge   : http://127.0.0.1:%PORT%
echo.
echo   Ready. Double-click agent.bat to chat ^(agent.bat 2 = menu model #2^).
pause >nul
'@
$setup = $setup -replace "`r`n", "`n" -replace "`n", "`r`n"
$b2 = [Text.Encoding]::ASCII.GetBytes($setup)
if (@($b2 | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'setup.bat not ASCII' }
[IO.File]::WriteAllBytes("$dst\setup.bat", $b2)

# 清掉旧的 config.json(现在由 agent.bat 每次生成)
Remove-Item "$dst\config.json" -Force -ErrorAction SilentlyContinue

Write-Host '=== RETRO-X86 v2 文件清单 ==='
Get-ChildItem $dst | ForEach-Object { '{0,-18} {1,8:N1}KB' -f $_.Name, ($_.Length/1KB) }
