#Requires -Version 5.1
<#
.SYNOPSIS
  清理本部署助手在测试时产生的本地配置/缓存/安装痕迹（谨慎使用）。
#>
[CmdletBinding()]
param(
    [switch]$RemoveAstrBotData,
    [switch]$RemoveInstallRoot,
    [switch]$RemoveDesktopShortcuts,
    [string]$InstallRoot = 'C:\ChiXiaoYangBot',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root 'runtime'
$logs = Join-Path $root 'logs'

Write-Host '将清理以下内容（按参数）:' -ForegroundColor Yellow
Write-Host " - 部署助手 runtime/logs: $runtime , $logs"
if ($RemoveInstallRoot) { Write-Host " - 安装目录: $InstallRoot" }
if ($RemoveAstrBotData) { Write-Host " - AstrBot 数据: $env:USERPROFILE\.astrbot" }
if ($RemoveDesktopShortcuts) { Write-Host ' - 桌面 AstrBot.lnk / 启动 NapCat QQ.bat' }

if (-not $Force) {
    $c = Read-Host '确认清理？输入 YES 继续'
    if ($c -ne 'YES') { Write-Host '已取消'; exit 0 }
}

Get-Process -Name 'AstrBot','astrbot-desktop-tauri','astrbot','QQ','NapCatWinBootMain','napimain','node' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

if (Test-Path $runtime) { Remove-Item -Recurse -Force $runtime }
if (Test-Path $logs) { Remove-Item -Recurse -Force $logs }
New-Item -ItemType Directory -Force -Path $runtime, $logs | Out-Null

Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '_inspect_*' -or $_.Name -like '_test_*' } |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

if ($RemoveInstallRoot -and (Test-Path $InstallRoot)) {
    Remove-Item -Recurse -Force $InstallRoot
}

if ($RemoveAstrBotData) {
    $data = Join-Path $env:USERPROFILE '.astrbot'
    if (Test-Path $data) { Remove-Item -Recurse -Force $data }
}

if ($RemoveDesktopShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    @(
        (Join-Path $desktop 'AstrBot.lnk'),
        (Join-Path $desktop '启动 NapCat QQ.bat')
    ) | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Force $_ }
    }
}

Write-Host '清理完成。' -ForegroundColor Green
