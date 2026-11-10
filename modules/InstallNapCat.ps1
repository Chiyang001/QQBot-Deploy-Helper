#Requires -Version 5.1

function Test-NapCatRuntimeReady {
    <#
    .SYNOPSIS
      判断 NapCat QQ 目录是否可启动。
      - Node 包：node.exe + index.js + napcat.bat + (wrapper.node|QQNT.dll)，无需单独下载 QQ.exe
      - OneKey/Shell：必须有 QQ.exe + 启动器；不可把空 bootmain 当成成功
    #>
    param([string]$NapCatDir)

    if ([string]::IsNullOrWhiteSpace($NapCatDir) -or -not (Test-Path -LiteralPath $NapCatDir)) {
        return $false
    }

    $hasNodeRuntime =
        (Test-Path -LiteralPath (Join-Path $NapCatDir 'node.exe')) -and
        (Test-Path -LiteralPath (Join-Path $NapCatDir 'index.js')) -and
        (Test-Path -LiteralPath (Join-Path $NapCatDir 'napcat.bat')) -and
        (
            (Test-Path -LiteralPath (Join-Path $NapCatDir 'wrapper.node')) -or
            (Test-Path -LiteralPath (Join-Path $NapCatDir 'QQNT.dll'))
        )
    if ($hasNodeRuntime) { return $true }

    $hasQq = Test-Path -LiteralPath (Join-Path $NapCatDir 'QQ.exe')
    $hasLauncher =
        (Test-Path -LiteralPath (Join-Path $NapCatDir 'napcat.bat')) -or
        (Test-Path -LiteralPath (Join-Path $NapCatDir 'NapCatWinBootMain.exe'))
    return ($hasQq -and $hasLauncher)
}

function Find-NapCatShellDir {
    param([string]$SearchRoot)
    if (-not $SearchRoot -or -not (Test-Path $SearchRoot)) { return $null }

    # 直接命中安装根下的 Node 解压目录
    if (Test-NapCatRuntimeReady -NapCatDir $SearchRoot) {
        return (Resolve-Path -LiteralPath $SearchRoot).Path
    }

    $hit = Get-ChildItem -Path $SearchRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (
                $_.Name -match '^NapCat\..+\.Shell$' -or
                $_.Name -match '^NCat\..+\.Shell$' -or
                $_.Name -eq 'Node'
            ) -and
            (Test-NapCatRuntimeReady -NapCatDir $_.FullName)
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }

    $nested = Get-ChildItem -Path $SearchRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-NapCatRuntimeReady -NapCatDir $_.FullName } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($nested) { return $nested.FullName }
    return $null
}

function Install-NapCatNodePackage {
    param(
        [string]$InstallRoot,
        [string]$ZipPath
    )

    Write-Step '安装 NapCat QQ（Node 完整包，离线可用，无需再下载 QQ）'
    Write-SubStep -Current 1 -Total 3 -Text '解压 NapCat.Shell.Windows.Node.zip'
    $dest = Join-Path $InstallRoot 'Node'
    Write-Detail "安装包: $ZipPath"
    Write-Detail "目标目录: $dest"
    Expand-ZipSafe -ZipPath $ZipPath -Destination $dest

    Write-SubStep -Current 2 -Total 3 -Text '定位可用运行目录'
    $shellDir = $null
    if (Test-NapCatRuntimeReady -NapCatDir $dest) {
        $shellDir = $dest
    }
    else {
        $shellDir = Find-NapCatShellDir -SearchRoot $dest
    }
    if (-not $shellDir) {
        throw @"
已解压 NapCat.Shell.Windows.Node.zip，但未找到可启动目录。
期望目录中包含: node.exe、index.js、napcat.bat，以及 wrapper.node 或 QQNT.dll。
解压位置: $dest
"@
    }

    Write-SubStep -Current 3 -Total 3 -Text '写入部署状态'
    Write-Ok "NapCat QQ（Node）安装完成: $shellDir"
    $files = @(Get-ChildItem -Path $shellDir -Force -ErrorAction SilentlyContinue | Select-Object -First 12 Name)
    Write-Detail ("目录内容预览: {0}" -f (($files | ForEach-Object { $_.Name }) -join ', '))
    Merge-DeployState @{
        NapCatDir         = $shellDir
        NapCatMode        = 'node'
        NapCatInstallRoot = $InstallRoot
        NapCatPackage     = 'NapCat.Shell.Windows.Node.zip'
    } | Out-Null
    return $shellDir
}

function Install-NapCatOneKeyLegacy {
    param([string]$InstallRoot)

    Write-Step '安装 NapCat QQ（OneKey 一键包备用路线，需联网下载 QQ）'
    Write-Warn '未使用 Node 完整包时才会走到此路线；腾讯 QQ CDN 可能返回 404。'

    $zip = Get-PackagePath -FileName 'NapCat.Shell.Windows.OneKey.zip'
    $extractDir = Join-Path $InstallRoot 'OneKey'
    $attempt = 0

    while ($true) {
        $attempt++
        Write-SubStep -Current 1 -Total 3 -Text ("解压并运行 NapCatInstaller（第 {0} 次尝试）" -f $attempt)
        Expand-ZipSafe -ZipPath $zip -Destination $extractDir

        $installer = Join-Path $extractDir 'NapCatInstaller.exe'
        if (-not (Test-Path $installer)) {
            throw "未找到 NapCatInstaller.exe: $installer"
        }
        Write-Detail "安装器: $installer"

        Write-SubStep -Current 2 -Total 3 -Text '运行 NapCatInstaller.exe（可见窗口，需联网）'
        Write-Info '正在运行 NapCatInstaller.exe（需联网下载内置 QQ/Shell）...'
        Write-Info '若出现“下载QQ失败/HTTP 404”，请关闭该窗口。更推荐改用 NapCat.Shell.Windows.Node.zip。'
        $p = Start-Process -FilePath $installer -WorkingDirectory $extractDir -PassThru
        $code = Wait-VisibleProcess -Process $p -DisplayName 'NapCatInstaller' -HeartbeatSec 3
        Write-Detail "NapCatInstaller 退出码: $code"
        if ($code -ne 0) {
            Write-Warn "NapCatInstaller 异常退出（退出码 $code）。常见原因：下载 QQ 失败（HTTP 404）。"
        }

        Write-SubStep -Current 3 -Total 3 -Text '校验是否生成可用的 NapCat Shell（须含 QQ.exe）'
        $shellDir = $null
        $deadline = if ($code -eq 0) { (Get-Date).AddMinutes(3) } else { (Get-Date).AddSeconds(12) }
        $round = 0
        while ((Get-Date) -lt $deadline) {
            $round++
            $shellDir = Find-NapCatShellDir -SearchRoot $extractDir
            if (-not $shellDir) {
                $shellDir = Find-NapCatShellDir -SearchRoot $InstallRoot
            }
            if ($shellDir) {
                Write-Status -State 'OK' -Text "第 $round 次扫描命中可用 Shell: $shellDir"
                break
            }
            $bootmain = Join-Path $extractDir 'bootmain'
            if ((Test-Path -LiteralPath $bootmain) -and -not (Test-Path -LiteralPath (Join-Path $bootmain 'QQ.exe'))) {
                Write-Status -State 'FAIL' -Text '仅发现 OneKey 自带 bootmain，尚未下载到 QQ.exe（安装未成功）'
                if ($code -ne 0) { break }
            }
            Write-Status -State 'WAIT' -Text "第 $round 次扫描尚未发现可用 Shell，2 秒后重试..."
            Start-Sleep -Seconds 2
        }

        if ($shellDir -and (Test-NapCatRuntimeReady -NapCatDir $shellDir)) {
            Write-Ok "NapCat Shell 安装完成: $shellDir"
            Merge-DeployState @{
                NapCatDir          = $shellDir
                NapCatMode         = 'onekey'
                NapCatInstallRoot  = $InstallRoot
                NapCatInstallTries = $attempt
                NapCatPackage      = 'NapCat.Shell.Windows.OneKey.zip'
            } | Out-Null
            return $shellDir
        }

        Write-Warn 'OneKey 安装未完成（未得到含 QQ.exe 的可用目录）。'
        Write-Host '建议：将 NapCat.Shell.Windows.Node.zip 放到部署助手根目录后重试（无需再下载 QQ）。' -ForegroundColor Yellow
        $choice = Read-UserChoice `
            -Prompt '请选择: r=立即重试 OneKey / a=中止本步骤' `
            -ValidChoices @('r', 'a') `
            -Default 'r'
        if ($choice -eq 'a') {
            throw @"
用户中止 NapCat QQ 安装（OneKey 备用路线失败，已尝试 $attempt 次）。
请将 NapCat.Shell.Windows.Node.zip 放到部署助手根目录后重新运行。
"@
        }
        Write-Info "准备进行第 $($attempt + 1) 次 OneKey 重试..."
        Start-Sleep -Seconds 1
    }
}

function Install-NapCatOneKey {
    Write-Step '安装 NapCat QQ'

    Write-SubStep -Current 1 -Total 3 -Text '准备安装目录'
    $installRoot = Join-Path $script:DefaultInstallRoot 'NapCat'
    Assert-AsciiPreferredPath -Path $installRoot
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Write-Detail "NapCat 安装根目录: $installRoot"
    Write-Info '优先使用 NapCat.Shell.Windows.Node.zip（内置 QQNT 运行时，避免 CDN 404）。'

    Write-SubStep -Current 2 -Total 3 -Text '检查是否已安装'
    $existing = Find-NapCatShellDir -SearchRoot $installRoot
    if ($existing) {
        Write-Ok "检测到已存在可用的 NapCat: $existing"
        Write-Detail '跳过安装，直接复用。'
        $mode = 'onekey'
        if (
            (Test-Path -LiteralPath (Join-Path $existing 'node.exe')) -and
            (Test-Path -LiteralPath (Join-Path $existing 'index.js'))
        ) {
            $mode = 'node'
        }
        Merge-DeployState @{ NapCatDir = $existing; NapCatMode = $mode } | Out-Null
        return $existing
    }

    Write-SubStep -Current 3 -Total 3 -Text '选择安装包并部署'
    $nodeZip = Join-Path $script:RootDir 'NapCat.Shell.Windows.Node.zip'
    if (Test-Path -LiteralPath $nodeZip) {
        Write-Ok "已找到 Node 完整包: $nodeZip"
        return (Install-NapCatNodePackage -InstallRoot $installRoot -ZipPath $nodeZip)
    }

    Write-Warn '未找到 NapCat.Shell.Windows.Node.zip，回退到 OneKey（可能因 QQ CDN 404 失败）。'
    $oneKeyZip = Join-Path $script:RootDir 'NapCat.Shell.Windows.OneKey.zip'
    if (-not (Test-Path -LiteralPath $oneKeyZip)) {
        throw @"
缺少 NapCat 安装包。
请将以下任一文件放到部署助手根目录后重试：
1) 推荐：NapCat.Shell.Windows.Node.zip（离线完整包，约 110MB）
2) 备用：NapCat.Shell.Windows.OneKey.zip（需联网下载 QQ，当前 CDN 常 404）
目录: $script:RootDir
"@
    }
    return (Install-NapCatOneKeyLegacy -InstallRoot $installRoot)
}

function Get-NapCatConfigDirs {
    <#
    .SYNOPSIS
      NapCat Node 包实际读取 napcat\config\（账号文件 onebot11_<QQ>.json）；
      旧 Shell/OneKey 可能用根目录 config\。两处都写，避免写错目录导致 WebUI 无连接。
    #>
    param([string]$NapCatDir)

    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @('napcat\config', 'config')) {
        $p = Join-Path $NapCatDir $rel
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        if (-not ($dirs -contains $p)) { $dirs.Add($p) | Out-Null }
    }
    return @($dirs)
}

function Get-NapCatWebUiInfo {
    param([string]$NapCatDir)
    $candidates = @(
        (Join-Path $NapCatDir 'napcat\config\webui.json'),
        (Join-Path $NapCatDir 'config\webui.json')
    )
    foreach ($p in $candidates) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $w = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $port = 6099
            if ($w.port) { $port = [int]$w.port }
            $token = ''
            if ($w.token) { $token = [string]$w.token }
            return @{
                Port  = $port
                Token = $token
                Url   = "http://127.0.0.1:$port"
                Path  = $p
            }
        }
        catch {}
    }
    return @{
        Port  = 6099
        Token = ''
        Url   = 'http://127.0.0.1:6099'
        Path  = ''
    }
}

function Set-NapCatWebsocketClientInFile {
    param(
        [string]$Path,
        [hashtable]$Client,
        [switch]$CreateIfMissing
    )

    $obj = $null
    if (Test-Path -LiteralPath $Path) {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    elseif ($CreateIfMissing) {
        $obj = [pscustomobject]@{
            network             = [pscustomobject]@{}
            musicSignUrl        = ''
            enableLocalFile2Url = $false
            parseMultMsg        = $false
        }
    }
    else {
        return $false
    }

    if (-not $obj.network) {
        $obj | Add-Member -NotePropertyName network -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    # 补齐新版 NapCat 常见字段，避免 WebUI 读配置时报结构不完整
    foreach ($name in @('httpServers', 'httpSseServers', 'httpClients', 'websocketServers', 'websocketClients', 'plugins')) {
        $prop = $obj.network.PSObject.Properties[$name]
        if (-not $prop) {
            $obj.network | Add-Member -NotePropertyName $name -NotePropertyValue @() -Force
        }
    }

    $clients = New-Object System.Collections.ArrayList
    foreach ($c in @($obj.network.websocketClients)) {
        if ($null -eq $c) { continue }
        if ([string]$c.name -eq 'AstrBot') { continue }
        [void]$clients.Add($c)
    }
    [void]$clients.Add([pscustomobject]$Client)
    $obj.network | Add-Member -NotePropertyName websocketClients -NotePropertyValue @($clients.ToArray()) -Force

    Write-JsonFile -Path $Path -InputObject $obj -Depth 12
    return $true
}

function New-NapCatOneBotConfig {
    param(
        [string]$NapCatDir,
        [int]$AstrBotWsPort
    )

    Write-Step '写入 NapCat WebSocket 客户端配置（对接 AstrBot 反向 WS）'
    if (-not (Test-Path -LiteralPath $NapCatDir)) {
        throw "NapCat 目录不存在: $NapCatDir"
    }

    $wsUrl = "ws://127.0.0.1:$AstrBotWsPort/ws"
    Write-Detail "NapCat 目录: $NapCatDir"
    Write-Detail "目标地址: $wsUrl （与官方文档一致；Token 留空）"
    Write-Info '等价于 NapCat WebUI：网络配置 → 新建 → WebSockets 客户端 → URL=上述地址'

    # 官方文档建议心跳/重连 1000ms
    $client = @{
        name              = 'AstrBot'
        enable            = $true
        url               = $wsUrl
        messagePostFormat = 'array'
        reportSelfMessage = $false
        reconnectInterval = 1000
        token             = ''
        debug             = $false
        heartInterval     = 1000
    }

    $configDirs = @(Get-NapCatConfigDirs -NapCatDir $NapCatDir)
    $updatedAccount = 0
    $primaryDir = $null

    foreach ($configDir in $configDirs) {
        Write-Detail "配置目录: $configDir"
        if (-not $primaryDir) { $primaryDir = $configDir }

        $defaultPath = Join-Path $configDir 'onebot11.json'
        [void](Set-NapCatWebsocketClientInFile -Path $defaultPath -Client $client -CreateIfMissing)
        Write-Ok "已写入默认 OneBot 配置: $defaultPath"

        Get-ChildItem -Path $configDir -Filter 'onebot11_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if (Set-NapCatWebsocketClientInFile -Path $_.FullName -Client $client) {
                    $updatedAccount++
                    Write-Ok "已更新账号配置: $($_.FullName)"
                }
            }
            catch {
                Write-Warn "更新 $($_.Name) 失败: $($_.Exception.Message)"
            }
        }
    }

    if ($updatedAccount -eq 0) {
        Write-Warn '尚未找到 onebot11_<QQ号>.json。请先完成 NapCat 扫码登录，登录后会再次写入账号配置。'
        Write-Warn '也可手动打开 NapCat WebUI（默认 http://127.0.0.1:6099）→ 网络配置 → 新建 WebSockets 客户端。'
    }
    else {
        Write-Ok ("已写入 {0} 个账号的 WebSocket 客户端（AstrBot）。" -f $updatedAccount)
    }

    $webui = Get-NapCatWebUiInfo -NapCatDir $NapCatDir
    Merge-DeployState @{
        OneBotToken       = ''
        OneBotWsPort      = $AstrBotWsPort
        OneBotWsUrl       = $wsUrl
        NapCatConfigDir   = $primaryDir
        NapCatWebUiUrl    = $webui.Url
        NapCatWebUiPort   = $webui.Port
        NapCatWebUiToken  = $webui.Token
    } | Out-Null

    Write-Info ("NapCat WebUI: {0} （Token 见 webui.json / 首次启动终端）" -f $webui.Url)
}

function New-NapCatDesktopLauncher {
    param([string]$NapCatDir)

    $desktop = [Environment]::GetFolderPath('Desktop')
    $batPath = Join-Path $desktop '启动 NapCat QQ.bat'

    if (-not (Test-NapCatRuntimeReady -NapCatDir $NapCatDir)) {
        throw @"
NapCat QQ 运行环境不完整，拒绝创建桌面启动脚本。
目录: $NapCatDir
请确认已用 NapCat.Shell.Windows.Node.zip 完成安装，或 OneKey 已成功下载 QQ.exe。
"@
    }

    $targetBat = Join-Path $NapCatDir 'napcat.bat'
    if (-not (Test-Path $targetBat)) {
        $targetBat = Join-Path $NapCatDir 'NapCatWinBootMain.exe'
    }
    if (-not (Test-Path $targetBat)) {
        throw "未找到 NapCat 启动文件于: $NapCatDir"
    }

    $content = @"
@echo off
setlocal
chcp 65001 >nul
title NapCat QQ
cd /d "$NapCatDir"
echo ========================================
echo   NapCat QQ 正在启动
echo   请在本窗口查看二维码，使用手机 QQ 扫码登录
echo   建议使用 QQ 小号；登录成功后可最小化，勿直接关闭
echo ========================================
echo.
if exist "napcat.bat" goto RUN_BAT
if exist "NapCatWinBootMain.exe" goto RUN_EXE
echo 未找到可用启动文件，请检查 NapCat 安装目录。
pause
exit /b 1

:RUN_BAT
call "napcat.bat"
goto END

:RUN_EXE
"NapCatWinBootMain.exe"
goto END

:END
endlocal
"@
    Write-BatchFile -Path $batPath -Content $content
    Write-Ok "已在桌面创建: $batPath"
    Merge-DeployState @{ NapCatDesktopBat = $batPath } | Out-Null
    return $batPath
}

function Start-NapCatForLogin {
    param([string]$NapCatDir)

    Write-Step '启动 NapCat QQ（扫码登录）'
    if (-not (Test-NapCatRuntimeReady -NapCatDir $NapCatDir)) {
        throw @"
无法启动 NapCat QQ：运行环境不完整。
目录: $NapCatDir
请返回安装步骤，使用 NapCat.Shell.Windows.Node.zip 重新安装。
"@
    }

    Write-Host ''
    Write-Orange '小贴士：建议使用 QQ 小号扫码登录机器人，降低主号封控/异常风险。'
    Write-Host '接下来将打开 NapCat 启动窗口。' -ForegroundColor Yellow
    Write-Host '请在命令行窗口中查看二维码，使用手机 QQ 扫码登录。' -ForegroundColor Yellow
    Write-Host '登录成功后，回到本窗口按 Enter 继续。' -ForegroundColor Yellow
    Write-Host ''

    $state = Get-DeployState
    $desktopBat = $null
    if ($state -is [hashtable]) { $desktopBat = $state['NapCatDesktopBat'] }
    if ($desktopBat -and (Test-Path -LiteralPath $desktopBat)) {
        # 直接启动 .bat，避免 cmd /c 再包一层造成多余回显
        Start-Process -FilePath $desktopBat -WorkingDirectory $NapCatDir | Out-Null
    }
    else {
        $napcatBat = Join-Path $NapCatDir 'napcat.bat'
        if (Test-Path -LiteralPath $napcatBat) {
            Start-Process -FilePath $napcatBat -WorkingDirectory $NapCatDir | Out-Null
        }
        else {
            Start-Process -FilePath (Join-Path $NapCatDir 'NapCatWinBootMain.exe') -WorkingDirectory $NapCatDir | Out-Null
        }
    }

    Read-Host '扫码登录完成后，按 Enter 继续' | Out-Null
    Write-Ok '已确认继续（请确保 NapCat 仍在运行）。'
}
