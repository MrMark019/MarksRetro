$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== 1) 删除 retro 测试目录 ==='
foreach ($d in @('C:\RETRO', "$env:USERPROFILE\RETRO")) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force; Write-Host "已删: $d" }
}

Write-Host '=== 2) 卸载 Pi(保留 ~/.pi 配置) ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File 'E:\opencode\scripts\uninstall-pi.ps1' -KeepConfig -NoPause
Write-Host "uninstall exit=$LASTEXITCODE"

Write-Host '=== 3) 删除 .nodejs(卸载器交互默认保留,这里手动清) ==='
if (Test-Path "$env:USERPROFILE\.nodejs") { Remove-Item "$env:USERPROFILE\.nodejs" -Recurse -Force; Write-Host '已删: ~\.nodejs' }

Write-Host '=== 4) 最终核验 ==='
Write-Host ("C:\RETRO 存在: " + (Test-Path 'C:\RETRO'))
Write-Host ("用户RETRO 存在: " + (Test-Path "$env:USERPROFILE\RETRO"))
Write-Host ("PiAgent 存在: " + (Test-Path "$env:LOCALAPPDATA\PiAgent"))
Write-Host ("~\.nodejs 存在: " + (Test-Path "$env:USERPROFILE\.nodejs"))
Write-Host ("~\.pi 保留: " + (Test-Path "$env:USERPROFILE\.pi"))
$up = [Environment]::GetEnvironmentVariable('Path','User')
Write-Host ("PATH 含 PiAgent: " + ($up -match 'PiAgent'))
Write-Host ("PATH 含 .nodejs: " + ($up -match '\\\.nodejs'))
$cmd = Get-Command pi -ErrorAction SilentlyContinue
Write-Host ("pi 命令: " + $(if ($cmd) { $cmd.Source } else { '已不可用 ✓' }))
$leftover = Get-CimInstance Win32_Process | Where-Object { $_.Name -in 'retrobridge.exe','micro-agent.exe' }
Write-Host ("retro 进程残留: " + $(if ($leftover) { '有!' } else { '无 ✓' }))
