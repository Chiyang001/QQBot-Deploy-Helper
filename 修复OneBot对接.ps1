#Requires -Version 5.1
<#
.SYNOPSIS
  仅重写 NapCat ↔ AstrBot OneBot 对接（无需完整重装）。
  修复「配置写到错误目录 / WebUI 无 WebSockets 客户端」问题。
#>
[CmdletBinding()]
param(
    [string]$NapCatDir = '',
    [string]$AstrBotExe = '',
    [int]$WsPort = 6199
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

$modulesDir = Join-Path $PSScriptRoot 'modules'
@(
    'Common.ps1',
    'InstallAstrBot.ps1',
    'InstallNapCat.ps1',
    'AstrBotApi.ps1',
    'AstrBotApi.ps1',
    'OneBotBridge.ps1'
) | ForEach-Object {
    . (Join-Path $modulesDir $_)
}

Initialize-DeployWorkspace
$state = Get-DeployState

if (-not $NapCatDir -and $state -is [hashtable] -and $state['NapCatDir']) {
    $NapCatDir = [string]$state['NapCatDir']
}
if (-not $AstrBotExe -and $state -is [hashtable] -and $state['AstrBotExe']) {
    $AstrBotExe = [string]$state['AstrBotExe']
}
if ($state -is [hashtable] -and $state['OneBotWsPort']) {
    $WsPort = [int]$state['OneBotWsPort']
}

if (-not $NapCatDir -or -not (Test-Path -LiteralPath $NapCatDir)) {
    $guess = Find-NapCatShellDir -SearchRoot ([Environment]::GetFolderPath('Desktop'))
    if (-not $guess) {
        $guess = Find-NapCatShellDir -SearchRoot $script:DefaultInstallRoot
    }
    if ($guess) { $NapCatDir = $guess }
}

if (-not $NapCatDir -or -not (Test-Path -LiteralPath $NapCatDir)) {
    throw '未找到 NapCat 目录。请用 -NapCatDir 指定，例如: -NapCatDir "C:\...\NapCat\Node"'
}
if (-not $AstrBotExe -or -not (Test-Path -LiteralPath $AstrBotExe)) {
    $AstrBotExe = Find-AstrBotExecutable
}
if (-not $AstrBotExe -or -not (Test-Path -LiteralPath $AstrBotExe)) {
    throw '未找到 AstrBot 可执行文件。请用 -AstrBotExe 指定。'
}

Write-Title '修复 OneBot 对接'
Write-Info "NapCat : $NapCatDir"
Write-Info "AstrBot: $AstrBotExe"
Write-Info "OneBot : ws://127.0.0.1:$WsPort/ws"

Write-Step '停止 AstrBot（含后端 python）'
[void](Stop-AstrBotProcesses -GraceSec 2 -EnsureStopped)
Start-Sleep -Seconds 1

Write-Step '写入 AstrBot OneBot 适配器'
Set-AstrBotPlatformInConfigFile -WsPort $WsPort

Write-Step '写入 NapCat WebSockets 客户端（含 napcat\config 账号文件）'
New-NapCatOneBotConfig -NapCatDir $NapCatDir -AstrBotWsPort $WsPort

Write-Step '启动 AstrBot 并等待 OneBot 端口'
$dash = 6185
if ($state -is [hashtable] -and $state['AstrBotDashboardPort']) {
    $dash = [int]$state['AstrBotDashboardPort']
}
$dash = Start-AstrBotApp -ExePath $AstrBotExe -DashboardPort $dash
Wait-AstrBotOneBotListening -WsPort $WsPort -TimeoutSec 90

$webui = Get-NapCatWebUiInfo -NapCatDir $NapCatDir
Merge-DeployState @{
    NapCatDir            = $NapCatDir
    AstrBotExe           = $AstrBotExe
    OneBotWsPort         = $WsPort
    OneBotWsUrl          = "ws://127.0.0.1:$WsPort/ws"
    AstrBotDashboardPort = $dash
    AstrBotDashboardUrl  = "http://127.0.0.1:$dash"
    NapCatWebUiUrl       = $webui.Url
    NapCatWebUiPort      = $webui.Port
    NapCatWebUiToken     = $webui.Token
} | Out-Null

Write-Title '修复完成'
Write-Host "AstrBot: http://127.0.0.1:$dash" -ForegroundColor Cyan
Write-Host "OneBot : ws://127.0.0.1:$WsPort/ws" -ForegroundColor Cyan
Write-Host "NapCat WebUI: $($webui.Url)" -ForegroundColor Cyan
if ($webui.Token) {
    Write-Host "NapCat Token: $($webui.Token)" -ForegroundColor DarkCyan
}
Write-Host ''
Write-Host '请启动 NapCat QQ（桌面 bat），登录后应自动连接 AstrBot。' -ForegroundColor Yellow
Write-Host '成功标志：AstrBot 日志出现「aiocqhttp(OneBot v11) 适配器已连接」' -ForegroundColor Yellow
Write-Host '也可在 NapCat WebUI → 网络配置 中确认已有启用的 WebSockets 客户端。' -ForegroundColor DarkGray
Write-Host ''
Read-Host '按 Enter 退出' | Out-Null
