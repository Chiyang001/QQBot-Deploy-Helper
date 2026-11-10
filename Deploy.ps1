#Requires -Version 5.1
<#
.SYNOPSIS
  炽小阳 QQ 机器人懒人一键部署助手（AstrBot + NapCat QQ）
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipNapCatLogin,
    [switch]$SkipModelConfig,
    [string]$InstallRoot = 'C:\ChiXiaoYangBot',
    [int]$MaxStepRetries = 3
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

$modulesDir = Join-Path $PSScriptRoot 'modules'
@(
    'Common.ps1',
    'EnvCheck.ps1',
    'InstallAstrBot.ps1',
    'InstallNapCat.ps1',
    'Desktop.ps1',
    'AstrBotApi.ps1',
    'OneBotBridge.ps1',
    'ModelConfig.ps1'
) | ForEach-Object {
    $path = Join-Path $modulesDir $_
    if (-not (Test-Path $path)) { throw "缺少模块: $path" }
    . $path
}

$script:DefaultInstallRoot = $InstallRoot
$script:DeployCtx = @{
    AstrBotExe     = $null
    DashboardPort  = 6185
    Token          = $null
    NapCatDir      = $null
    SavedUser      = 'astrbot'
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  炽小阳 QQ 机器人部署助手' -ForegroundColor Magenta
    Write-Host '  AstrBot + NapCat QQ 懒人一键部署包' -ForegroundColor Magenta
    Write-Host '  ----------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  本向导将按顺序完成下列阶段：' -ForegroundColor DarkGray
    Write-Host '    0) 环境检测与 VC 运行库' -ForegroundColor DarkGray
    Write-Host '    1) 安装 NapCat QQ 并创建桌面脚本' -ForegroundColor DarkGray
    Write-Host '    2) 安装并启动 AstrBot' -ForegroundColor DarkGray
    Write-Host '    3) 准备 AstrBot（无需登录面板）' -ForegroundColor DarkGray
    Write-Host '    4) OneBot 端口衔接' -ForegroundColor DarkGray
    Write-Host '    5) NapCat QQ 扫码登录' -ForegroundColor DarkGray
    Write-Host '    6) 模型接口配置与校验' -ForegroundColor DarkGray
    Write-Host '    7) 重启 AstrBot 以加载全部配置' -ForegroundColor DarkGray
    Write-Host '  控制台会持续打印当前阶段、子进度与等待状态。' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-DeployStepWithRetry {
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [int]$MaxRetries = 3
    )

    $index = 0
    $retryMap = @{}
    $titles = @($Steps | ForEach-Object { [string]$_.Title })

    while ($index -lt $Steps.Count) {
        $step = $Steps[$index]
        $name = [string]$step.Name
        if (-not $retryMap.ContainsKey($name)) { $retryMap[$name] = 0 }

        try {
            Write-ProgressRoadmap -Titles $titles -CurrentIndex $index
            Write-Title ("主步骤 {0}/{1}: {2}" -f ($index + 1), $Steps.Count, $step.Title)
            Write-Status -State 'RUN' -Text ("正在执行主步骤 {0}/{1} — {2}" -f ($index + 1), $Steps.Count, $step.Title)
            Write-Detail ("步骤标识: {0} | 本步已失败重试次数: {1}/{2}" -f $name, $retryMap[$name], $MaxRetries)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & $step.Action
            Write-Status -State 'OK' -Text ("主步骤完成: {0}（耗时 {1:N1}s）" -f $step.Title, $sw.Elapsed.TotalSeconds)
            Write-Ok ("进度: 已完成 {0}/{1} 个主步骤" -f ($index + 1), $Steps.Count)
            $index++
        }
        catch {
            $retryMap[$name]++
            $err = $_.Exception.Message
            Write-Host ''
            Write-Err "步骤失败 [$($step.Title)]: $err"
            if ($_.ScriptStackTrace) {
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
            }

            Merge-DeployState @{
                LastError     = $err
                FailedStep    = $name
                FailedAt      = (Get-Date).ToString('s')
                Success       = $false
            } | Out-Null

            if ($retryMap[$name] -gt $MaxRetries) {
                Write-Err "步骤 [$($step.Title)] 已连续失败 $($retryMap[$name]) 次，超过上限 $MaxRetries。"
                $choice = Read-UserChoice -Prompt '请选择: r=再试一次 / b=回退上一步 / a=中止' -ValidChoices @('r', 'b', 'a') -Default 'b'
                if ($choice -eq 'a') { throw "用户中止部署。最后错误: $err" }
                if ($choice -eq 'b') {
                    $index = [Math]::Max(0, $index - 1)
                    $retryMap[$Steps[$index].Name] = 0
                    Write-Warn "已返回上一步: $($Steps[$index].Title)"
                    continue
                }
                $retryMap[$name] = $MaxRetries
                Write-Warn '按选择再次重试当前步骤...'
                Start-Sleep -Seconds 2
                continue
            }

            # 自动：报错后回退上一步并重试
            if ($index -gt 0) {
                $prev = $Steps[$index - 1]
                Write-Warn "将自动返回上一步 [$($prev.Title)]，然后重新执行当前步骤（第 $($retryMap[$name])/$MaxRetries 次重试）..."
                $index = $index - 1
                Start-Sleep -Seconds 2
            }
            else {
                Write-Warn "当前已是第一步，将自动重试（第 $($retryMap[$name])/$MaxRetries 次）..."
                Start-Sleep -Seconds 2
            }
        }
    }
}

try {
    Show-Banner
    Initialize-DeployWorkspace
    Start-DeployTranscript
    Write-Info '模式: 可见安装 + 控制台详细进度（非静默）'
    Write-Detail "InstallRoot=$InstallRoot | DryRun=$DryRun | SkipNapCatLogin=$SkipNapCatLogin | SkipModelConfig=$SkipModelConfig"
    Merge-DeployState @{
        StartedAt   = (Get-Date).ToString('s')
        InstallRoot = $InstallRoot
        DryRun      = [bool]$DryRun
        VerboseUi   = $true
    } | Out-Null

    Invoke-EnvironmentCheck -DryRun:$DryRun

    if ($DryRun) {
        Write-Title 'DryRun 模式'
        Write-Ok '环境检测通过。未执行实际安装。'
        exit 0
    }

    Write-Host ''
    Write-Host "默认安装目录: $InstallRoot" -ForegroundColor Cyan
    $custom = Read-Host '如需修改安装根目录请输入新路径（直接回车使用默认）'
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        $InstallRoot = $custom.Trim().Trim('"')
        $script:DefaultInstallRoot = $InstallRoot
    }
    Assert-AsciiPreferredPath -Path $InstallRoot
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    Merge-DeployState @{ InstallRoot = $InstallRoot } | Out-Null

    $steps = @(
        @{
            Name  = 'InstallNapCat'
            Title = '安装 NapCat QQ 并创建桌面脚本'
            Action = {
                $script:DeployCtx.NapCatDir = Install-NapCatOneKey
                Install-NapCatDesktopShortcut | Out-Null
            }
        },
        @{
            Name  = 'InstallAstrBot'
            Title = '安装并启动 AstrBot'
            Action = {
                $script:DeployCtx.AstrBotExe = Install-AstrBotDesktop
                Install-AstrBotDesktopShortcut | Out-Null
                $script:DeployCtx.DashboardPort = Start-AstrBotApp -ExePath $script:DeployCtx.AstrBotExe
            }
        },
        @{
            Name  = 'AstrBotPrepare'
            Title = '准备 AstrBot（无需登录面板）'
            Action = {
                Write-Info '部署全程不要求登录 AstrBot 面板，也不设置/修改密码。'
                Write-Info 'OneBot 与模型配置将直接写入本地配置文件。'
                $script:DeployCtx.Token = ''
                Merge-DeployState @{
                    AstrBotUseConfigFile   = $true
                    AstrBotPasswordChanged = $false
                    AstrBotToken           = ''
                } | Out-Null
            }
        },
        @{
            Name  = 'OneBotBridge'
            Title = 'OneBot 端口衔接'
            Action = {
                if (-not $script:DeployCtx.NapCatDir) {
                    throw 'NapCat 目录为空，请先完成 NapCat 安装步骤。'
                }
                [void](Initialize-OneBotBridge `
                        -Token '' `
                        -NapCatDir $script:DeployCtx.NapCatDir `
                        -PreferredPort 6199 `
                        -DashboardPort $script:DeployCtx.DashboardPort)
            }
        },
        @{
            Name  = 'NapCatLogin'
            Title = 'NapCat QQ 扫码登录'
            Action = {
                if ($SkipNapCatLogin) {
                    Write-Warn '已跳过 NapCat 扫码登录步骤。'
                    return
                }
                if (-not $script:DeployCtx.NapCatDir) {
                    throw 'NapCat 目录为空，无法启动扫码登录。'
                }
                Start-NapCatForLogin -NapCatDir $script:DeployCtx.NapCatDir

                # 登录后 NapCat 会生成 onebot11_<QQ>.json，需再次写入 AstrBot 客户端
                $state = Get-DeployState
                $port = 0
                if ($state -is [hashtable] -and $state['OneBotWsPort']) {
                    $port = [int]$state['OneBotWsPort']
                }
                if ($port -le 0) { $port = 6199 }
                Write-Step '扫码完成后，重写 NapCat OneBot 客户端（含账号配置）'
                New-NapCatOneBotConfig -NapCatDir $script:DeployCtx.NapCatDir -AstrBotWsPort $port
            }
        },
        @{
            Name  = 'ModelConfig'
            Title = '模型接口配置与校验'
            Action = {
                if ($SkipModelConfig) {
                    Write-Warn '已跳过模型配置步骤。'
                    return
                }
                # 写入前确保 AstrBot 已停，避免退出时覆盖 provider/platform
                [void](Stop-AstrBotProcesses -GraceSec 1 -EnsureStopped)
                $script:DeployCtx.Token = ''
                Invoke-ModelConfigurationWizard -Token '' -Port $script:DeployCtx.DashboardPort
            }
        },
        @{
            Name  = 'RestartAstrBot'
            Title = '重启 AstrBot 以加载全部配置'
            Action = {
                Write-Step '模型配置已确认，正在重启 AstrBot 以加载 OneBot 与模型配置'
                if (-not $script:DeployCtx.AstrBotExe) {
                    $script:DeployCtx.AstrBotExe = (Get-DeployState).AstrBotExe
                }
                $state = Get-DeployState
                $wsPort = 6199
                if ($state -is [hashtable] -and $state['OneBotWsPort']) {
                    $wsPort = [int]$state['OneBotWsPort']
                }

                [void](Stop-AstrBotProcesses -GraceSec 2 -EnsureStopped)
                Start-Sleep -Seconds 1
                Assert-AstrBotPlatformOnDisk -WsPort $wsPort

                # 启动前再刷一次 NapCat，确保账号配置指向正确端口
                if ($script:DeployCtx.NapCatDir) {
                    New-NapCatOneBotConfig -NapCatDir $script:DeployCtx.NapCatDir -AstrBotWsPort $wsPort
                }

                $script:DeployCtx.DashboardPort = Start-AstrBotApp -ExePath $script:DeployCtx.AstrBotExe -DashboardPort $script:DeployCtx.DashboardPort
                Wait-AstrBotOneBotListening -WsPort $wsPort -TimeoutSec 90
                Write-Ok 'AstrBot 已重启并加载最新配置。请在「机器人」页确认 OneBot(napcat) 已出现。'
            }
        }
    )

    Invoke-DeployStepWithRetry -Steps $steps -MaxRetries $MaxStepRetries

    Merge-DeployState @{
        FinishedAt = (Get-Date).ToString('s')
        Success    = $true
    } | Out-Null

    Write-Title '部署完成'
    $state = Get-DeployState
    Write-Host "AstrBot 面板: $($state.AstrBotDashboardUrl)" -ForegroundColor Cyan
    Write-Host "OneBot 地址 : $($state.OneBotWsUrl)" -ForegroundColor Cyan
    if ($state.NapCatWebUiUrl) {
        Write-Host "NapCat WebUI: $($state.NapCatWebUiUrl)" -ForegroundColor Cyan
        if ($state.NapCatWebUiToken) {
            Write-Host "NapCat Token: $($state.NapCatWebUiToken)" -ForegroundColor DarkCyan
        }
    }
    Write-Host "桌面 AstrBot: $($state.AstrBotDesktopLnk)" -ForegroundColor Cyan
    Write-Host "桌面 NapCat : $($state.NapCatDesktopBat)" -ForegroundColor Cyan
    Write-Host ''
    Write-Orange 'Bingo！你已经完成了QQ机器人和Napcat QQ的初始化安装部署。'
    Write-Host ''
    Write-Host '对接说明（与官方一致）：' -ForegroundColor DarkGray
    Write-Host '  NapCat WebUI → 网络配置 → WebSockets 客户端 → ws://127.0.0.1:6199/ws' -ForegroundColor DarkGray
    Write-Host '  助手已自动写入该客户端；AstrBot 日志出现「aiocqhttp(OneBot v11) 适配器已连接」即成功。' -ForegroundColor DarkGray
    Write-Host '建议启动顺序: 1) 桌面 AstrBot  2) 桌面启动 NapCat QQ.bat（建议小号）' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '按 Enter 退出' | Out-Null
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Merge-DeployState @{
        LastError = $_.Exception.Message
        FailedAt  = (Get-Date).ToString('s')
        Success   = $false
    } | Out-Null
    Write-Host ''
    Read-Host '部署失败，按 Enter 退出' | Out-Null
    exit 1
}
