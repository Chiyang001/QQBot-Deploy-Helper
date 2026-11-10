#Requires -Version 5.1
<#
.SYNOPSIS
  炽小阳 QQ 机器人一键卸载：清除本助手部署产生的安装与配置。
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [switch]$KeepAstrBotData,
    [switch]$Force,
    [switch]$SkipSplash
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

$root = $PSScriptRoot
. (Join-Path $root 'modules\Common.ps1')
Initialize-DeployWorkspace
Start-DeployTranscript

function Write-UninstallBanner {
    Write-Title '炽小阳 · 一键卸载'
    Write-Host '  将尝试清除本助手部署过的 AstrBot / NapCat / 桌面入口 / 本地数据' -ForegroundColor DarkGray
    Write-Host '  不会卸载系统级 VC++ 运行库，也不会删除本目录中的安装包文件' -ForegroundColor DarkGray
    Write-Host ''
}

function Get-UninstallTargets {
    $state = Get-DeployState
    $targets = @{
        InstallRoot     = 'C:\ChiXiaoYangBot'
        AstrBotExe      = $null
        AstrBotDataDir  = (Join-Path $env:USERPROFILE '.astrbot')
        NapCatDir       = $null
        DesktopAstrBot  = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AstrBot.lnk')
        DesktopNapCat   = (Join-Path ([Environment]::GetFolderPath('Desktop')) '启动 NapCat QQ.bat')
        RuntimeDir      = $script:RuntimeDir
        LogsDir         = $script:LogsDir
    }

    if ($InstallRoot) {
        $targets.InstallRoot = $InstallRoot
    }
    elseif ($state.InstallRoot) {
        $targets.InstallRoot = [string]$state.InstallRoot
    }
    if ($state.AstrBotExe) { $targets.AstrBotExe = [string]$state.AstrBotExe }
    if ($state.AstrBotDataDir) { $targets.AstrBotDataDir = [string]$state.AstrBotDataDir }
    if ($state.AstrBotInstallDir -and -not $InstallRoot) {
        # 若状态里有更精确的安装根，优先用其父级 ChiXiaoYangBot
        $aid = [string]$state.AstrBotInstallDir
        $parent = Split-Path -Parent $aid
        if ($parent -and (Split-Path -Leaf $parent) -match 'ChiXiaoYang|AstrBot|NapCat') {
            # keep InstallRoot from state if present
        }
    }
    if ($state.NapCatDir) { $targets.NapCatDir = [string]$state.NapCatDir }
    if ($state.AstrBotDesktopLnk) { $targets.DesktopAstrBot = [string]$state.AstrBotDesktopLnk }
    if ($state.NapCatDesktopBat) { $targets.DesktopNapCat = [string]$state.NapCatDesktopBat }

    return $targets
}

function Stop-DeployedProcesses {
    Write-Step '停止相关进程'
    Write-SubStep -Current 1 -Total 2 -Text '结束 AstrBot / NapCat / 相关 QQ 注入进程'

    $names = @(
        'AstrBot', 'astrbot-desktop-tauri', 'astrbot',
        'NapCatWinBootMain', 'napimain', 'NapCatInstaller'
    )
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            Write-Detail ("结束进程 {0} (PID {1})" -f $p.ProcessName, $p.Id)
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
                Write-Warn "无法结束 $($p.ProcessName): $($_.Exception.Message)"
            }
        }
    }

    Write-SubStep -Current 2 -Total 2 -Text '扫描 AstrBot 后端 python / launch_backend'
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and (
                    $_.CommandLine -match 'launch_backend\.py' -or
                    $_.CommandLine -match '\\AstrBot\\' -or
                    $_.CommandLine -match '\\ChiXiaoYangBot\\' -or
                    $_.CommandLine -match 'astrbot-desktop'
                )
            } |
            ForEach-Object {
                Write-Detail ("结束命令行匹配进程 PID {0}: {1}" -f $_.ProcessId, $_.Name)
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
    }
    catch {
        Write-Detail "WMI 扫描跳过: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 1
    Write-Ok '进程清理完成（如仍有残留可手动结束任务管理器中的相关项）'
}

function Invoke-AstrBotUninstaller {
    param([hashtable]$Targets)

    Write-Step '尝试运行 AstrBot 卸载程序（若存在）'
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Targets.AstrBotExe -and (Test-Path $Targets.AstrBotExe)) {
        $dir = Split-Path -Parent $Targets.AstrBotExe
        @(
            (Join-Path $dir 'uninstall.exe'),
            (Join-Path $dir 'Uninstall.exe'),
            (Join-Path $dir 'uninst.exe')
        ) | ForEach-Object { if (Test-Path $_) { $candidates.Add($_) | Out-Null } }
    }

    @(
        (Join-Path $env:LOCALAPPDATA 'Programs\AstrBot\uninstall.exe'),
        (Join-Path $env:LOCALAPPDATA 'AstrBot\uninstall.exe'),
        (Join-Path ${env:ProgramFiles} 'AstrBot\uninstall.exe')
    ) | ForEach-Object {
        if ($_ -and (Test-Path $_)) { $candidates.Add($_) | Out-Null }
    }

    # 开始菜单卸载项
    $sm = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($base in $sm) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -Recurse -Filter '*AstrBot*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
                if ($sc.TargetPath -and $sc.TargetPath -match 'uninstall|uninst' -and (Test-Path $sc.TargetPath)) {
                    $candidates.Add($sc.TargetPath) | Out-Null
                }
            }
            catch {}
        }
    }

    $uniq = $candidates | Select-Object -Unique
    if (-not $uniq -or $uniq.Count -eq 0) {
        Write-Info '未找到 AstrBot 专用卸载程序，稍后将直接删除安装目录。'
        return
    }

    $uninstaller = $uniq[0]
    Write-Info "发现卸载程序: $uninstaller"
    Write-Detail '将以可见方式启动；若弹出确认框请选择卸载/是。'
    try {
        $p = Start-Process -FilePath $uninstaller -PassThru -ErrorAction Stop
        [void](Wait-VisibleProcess -Process $p -DisplayName 'AstrBot 卸载程序' -HeartbeatSec 2)
    }
    catch {
        Write-Warn "启动卸载程序失败: $($_.Exception.Message)"
    }
}

function Remove-PathSafe {
    param(
        [string]$Path,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Detail "$Label : 路径为空，跳过"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Detail "$Label : 不存在 -> $Path"
        return $false
    }
    Write-Status -State 'RUN' -Text "正在删除 $Label ..."
    Write-Detail $Path
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Status -State 'OK' -Text "已删除 $Label"
        return $true
    }
    catch {
        Write-Status -State 'FAIL' -Text "删除失败: $Label — $($_.Exception.Message)"
        return $false
    }
}

function Remove-StartMenuAstrBot {
    Write-Step '清理开始菜单 AstrBot 快捷方式'
    $roots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    $n = 0
    foreach ($base in $roots) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -Recurse -Filter '*AstrBot*' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction Stop
                Write-Detail "已删: $($_.FullName)"
                $n++
            }
            catch {
                Write-Warn "无法删除 $($_.FullName): $($_.Exception.Message)"
            }
        }
    }
    Write-Ok "开始菜单清理完成（$n 项）"
}

try {
    Write-UninstallBanner
    $targets = Get-UninstallTargets

    Write-Step '即将清除的目标预览'
    Write-Info "安装根目录: $($targets.InstallRoot)"
    Write-Info "AstrBot 数据: $($targets.AstrBotDataDir)"
    Write-Info "桌面 AstrBot: $($targets.DesktopAstrBot)"
    Write-Info "桌面 NapCat : $($targets.DesktopNapCat)"
    if ($targets.NapCatDir) { Write-Detail "状态中的 NapCatDir: $($targets.NapCatDir)" }
    if ($targets.AstrBotExe) { Write-Detail "状态中的 AstrBotExe: $($targets.AstrBotExe)" }
    if ($KeepAstrBotData) { Write-Warn '已指定 -KeepAstrBotData，将保留 .astrbot 数据目录' }

    Write-Host ''
    Write-Host '警告：此操作不可自动恢复！' -ForegroundColor Red
    if (-not $Force) {
        $confirm = Read-Host '确认卸载请输入 YES（其他输入取消）'
        if ($confirm -ne 'YES') {
            Write-Warn '已取消卸载。'
            exit 0
        }
    }

    $uninstallTitles = @(
        '停止相关进程',
        '运行 AstrBot 卸载程序（若存在）',
        '删除安装根目录',
        '删除桌面入口与开始菜单快捷方式',
        '删除 AstrBot 用户数据',
        '清理部署助手运行时状态'
    )

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 0 -Header '卸载总览'
    Write-Title '卸载主步骤 1/6: 停止相关进程'
    Write-Status -State 'RUN' -Text '正在结束 AstrBot / NapCat / 相关进程...'
    Stop-DeployedProcesses
    Write-Ok '主步骤 1/6 完成：进程已尽量停止'

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 1 -Header '卸载总览'
    Write-Title '卸载主步骤 2/6: 运行 AstrBot 卸载程序（若存在）'
    Write-Status -State 'RUN' -Text '正在查找并运行 AstrBot 卸载程序...'
    Invoke-AstrBotUninstaller -Targets $targets
    Write-Ok '主步骤 2/6 完成：卸载程序阶段结束'

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 2 -Header '卸载总览'
    Write-Title '卸载主步骤 3/6: 删除安装根目录'
    Write-Status -State 'RUN' -Text ("正在删除安装根目录: {0}" -f $targets.InstallRoot)
    [void](Remove-PathSafe -Path $targets.InstallRoot -Label '安装根目录')
    Write-Ok '主步骤 3/6 完成：安装根目录已处理'

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 3 -Header '卸载总览'
    Write-Title '卸载主步骤 4/6: 删除桌面入口与开始菜单快捷方式'
    Write-Status -State 'RUN' -Text '正在删除桌面与开始菜单入口...'
    [void](Remove-PathSafe -Path $targets.DesktopAstrBot -Label '桌面 AstrBot 快捷方式')
    [void](Remove-PathSafe -Path $targets.DesktopNapCat -Label '桌面 NapCat 启动脚本')
    Remove-StartMenuAstrBot
    Write-Ok '主步骤 4/6 完成：桌面/开始菜单入口已处理'

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 4 -Header '卸载总览'
    Write-Title '卸载主步骤 5/6: 删除 AstrBot 用户数据'
    if ($KeepAstrBotData) {
        Write-Info "已保留: $($targets.AstrBotDataDir)"
    }
    else {
        Write-Status -State 'RUN' -Text ("正在删除用户数据: {0}" -f $targets.AstrBotDataDir)
        [void](Remove-PathSafe -Path $targets.AstrBotDataDir -Label 'AstrBot 数据目录 (.astrbot)')
    }
    Write-Ok '主步骤 5/6 完成：用户数据阶段结束'

    Write-ProgressRoadmap -Titles $uninstallTitles -CurrentIndex 5 -Header '卸载总览'
    Write-Title '卸载主步骤 6/6: 清理部署助手运行时状态'
    Write-Status -State 'RUN' -Text '正在清空 runtime 状态目录...'
    # 清 runtime 状态，保留 logs 便于审计；再重建空 runtime
    if (Test-Path $targets.RuntimeDir) {
        Get-ChildItem -Path $targets.RuntimeDir -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    New-Item -ItemType Directory -Force -Path $targets.RuntimeDir | Out-Null
    Write-Ok '主步骤 6/6 完成：runtime 状态已清空'

    # 清理助手目录下临时解压残留
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '_inspect_*' -or $_.Name -like '_test_*' } |
        ForEach-Object {
            Write-Detail "清理临时目录: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

    Write-Title '卸载完成'
    Write-Ok '已尽可能清除本助手部署的内容。'
    Write-Info '如需重新部署，请再次运行「一键部署.bat」。'
    Write-Detail "日志: $($script:DeployLogFile)"
    Write-Host ''
    Write-Orange '炽焰已熄。若仍有残留，请检查任务管理器与安装目录后手动删除。'
    Write-Host ''
    Read-Host '按 Enter 退出' | Out-Null
}
catch {
    Write-Err $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Write-Host ''
    Read-Host '卸载失败，按 Enter 退出' | Out-Null
    exit 1
}
