#Requires -Version 5.1

function New-DesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = '',
        [string]$Description = ''
    )

    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $TargetPath
    if ($Arguments) { $sc.Arguments = $Arguments }
    if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
    if ($IconLocation) { $sc.IconLocation = $IconLocation }
    if ($Description) { $sc.Description = $Description }
    $sc.Save()
}

function Install-AstrBotDesktopShortcut {
    Write-Step '创建 AstrBot 桌面快捷方式'

    $desktop = [Environment]::GetFolderPath('Desktop')
    $state = Get-DeployState
    $astrbotExe = $state.AstrBotExe
    if (-not $astrbotExe) { $astrbotExe = Find-AstrBotExecutable }
    if (-not $astrbotExe -or -not (Test-Path $astrbotExe)) {
        throw '无法创建 AstrBot 快捷方式：未找到 AstrBot.exe'
    }

    $astrbotLnk = Join-Path $desktop 'AstrBot.lnk'
    New-DesktopShortcut `
        -ShortcutPath $astrbotLnk `
        -TargetPath $astrbotExe `
        -WorkingDirectory (Split-Path -Parent $astrbotExe) `
        -IconLocation $astrbotExe `
        -Description 'AstrBot 桌面版'
    Write-Ok "已创建 AstrBot 桌面快捷方式: $astrbotLnk"
    Merge-DeployState @{ AstrBotDesktopLnk = $astrbotLnk } | Out-Null
    return $astrbotLnk
}

function Install-NapCatDesktopShortcut {
    Write-Step '创建 NapCat QQ 桌面启动脚本'

    $state = Get-DeployState
    $napcatDir = $state.NapCatDir
    if (-not $napcatDir -or -not (Test-Path $napcatDir)) {
        throw '无法创建 NapCat 快捷方式：未找到 NapCat 安装目录'
    }
    $bat = New-NapCatDesktopLauncher -NapCatDir $napcatDir
    Merge-DeployState @{ NapCatDesktopBat = $bat } | Out-Null
    return $bat
}

function Install-DesktopShortcuts {
    Install-AstrBotDesktopShortcut | Out-Null
    $state = Get-DeployState
    if ($state.NapCatDir) {
        Install-NapCatDesktopShortcut | Out-Null
    }
}
