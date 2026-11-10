#Requires -Version 5.1

function Get-AstrBotProcesses {
    <#
    .SYNOPSIS
      查找 AstrBot 相关进程：
      - 桌面壳 astrbot-desktop-tauri.exe
      - 独立残留的 backend\python\python.exe（launch_backend.py）
      只杀桌面壳时后端常成孤儿并继续占用 6185，导致配置不重载。
    #>
    $exeHint = ''
    $installHint = ''
    try {
        $state = Get-DeployState
        if ($state -is [hashtable] -and $state['AstrBotExe']) {
            $exeHint = [string]$state['AstrBotExe']
            if ($exeHint) {
                $installHint = [IO.Path]::GetDirectoryName($exeHint)
            }
        }
        if ($state -is [hashtable] -and $state['AstrBotInstallDir']) {
            $installHint = [string]$state['AstrBotInstallDir']
        }
    }
    catch {}

    $map = @{}
    $nameCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('AstrBot', 'astrbot-desktop-tauri', 'astrbot')) {
        $nameCandidates.Add($n) | Out-Null
    }
    if ($exeHint) {
        $hintLeaf = [IO.Path]::GetFileNameWithoutExtension($exeHint)
        if ($hintLeaf -and -not ($nameCandidates -contains $hintLeaf)) {
            $nameCandidates.Add($hintLeaf) | Out-Null
        }
    }

    foreach ($n in $nameCandidates) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            $map[$_.Id] = $_
        }
    }

    # WMI：桌面壳 + AstrBot 自带的 launch_backend.py / backend\python
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                if (-not $_.Name) { return $false }
                if ($_.Name -match '(?i)^astrbot') { return $true }
                if ($exeHint -and $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $exeHint, [StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
                $cmd = [string]$_.CommandLine
                if (-not $cmd) { return $false }
                if ($cmd -match '(?i)launch_backend\.py') { return $true }
                if ($cmd -match '(?i)AstrBot[\\/]+backend[\\/]+python[\\/]+python\.exe') { return $true }
                if ($installHint -and $cmd -like "*${installHint}*" -and $cmd -match '(?i)python\.exe') {
                    return $true
                }
                return $false
            } |
            ForEach-Object {
                $proc = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
                if ($proc) { $map[$proc.Id] = $proc }
            }
    }
    catch {}

    # 兜底：占用仪表盘端口的进程（通常是残留 backend）
    try {
        $dashPort = 6185
        $state2 = Get-DeployState
        if ($state2 -is [hashtable] -and $state2['AstrBotDashboardPort']) {
            $dashPort = [int]$state2['AstrBotDashboardPort']
        }
        Get-NetTCPConnection -LocalPort $dashPort -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object {
                $owningPid = $_.OwningProcess
                if (-not $owningPid) { return }
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$owningPid" -ErrorAction SilentlyContinue
                if (-not $cim) { return }
                $cmd = [string]$cim.CommandLine
                $path = [string]$cim.ExecutablePath
                if (
                    ($cmd -match '(?i)astrbot|launch_backend') -or
                    ($path -match '(?i)AstrBot[\\/]+backend') -or
                    ($installHint -and $path -like "*${installHint}*")
                ) {
                    $proc = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
                    if ($proc) { $map[$proc.Id] = $proc }
                }
            }
    }
    catch {}

    return @($map.Values | Sort-Object Id)
}

function Stop-AstrBotProcesses {
    param(
        [int]$GraceSec = 2,
        [switch]$EnsureStopped
    )

    $list = @(Get-AstrBotProcesses)
    if (@($list).Count -eq 0) {
        Write-Detail '未发现正在运行的 AstrBot 进程。'
        return 0
    }

    Write-Info ("将结束 {0} 个 AstrBot 相关进程..." -f @($list).Count)
    foreach ($p in $list) {
        $pathText = ''
        try { $pathText = $p.Path } catch {}
        Write-Detail ("请求退出: {0} PID={1} {2}" -f $p.ProcessName, $p.Id, $pathText)
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds $GraceSec

    foreach ($p in @(Get-AstrBotProcesses)) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Ok ("已强制结束: {0} PID={1}" -f $p.ProcessName, $p.Id)
        }
        catch {
            Write-Warn ("结束失败 PID={0}: {1}" -f $p.Id, $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds 1

    $left = @(Get-AstrBotProcesses)
    if (@($left).Count -gt 0) {
        Write-Warn ("仍有 {0} 个 AstrBot 相关进程残留。" -f @($left).Count)
        if ($EnsureStopped) {
            foreach ($p in $left) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                }
                catch {}
            }
            Start-Sleep -Seconds 1
            $left = @(Get-AstrBotProcesses)
            if (@($left).Count -gt 0) {
                throw ("无法结束 AstrBot 进程，残留 PID: {0}" -f (($left | Select-Object -ExpandProperty Id) -join ','))
            }
        }
    }
    else {
        Write-Ok 'AstrBot 相关进程已全部结束。'
    }
    return @($list).Count
}

function Assert-AstrBotPlatformOnDisk {
    param([int]$WsPort)

    $cfgPath = Join-Path (Get-AstrBotDataDir) 'data\cmd_config.json'
    if (-not (Test-Path $cfgPath)) {
        throw "未找到 AstrBot 配置: $cfgPath"
    }
    $json = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $plats = @($json.platform)
    $hit = $plats | Where-Object {
        $_.type -eq 'aiocqhttp' -and [bool]$_.enable -and ([int]$_.ws_reverse_port -eq $WsPort)
    } | Select-Object -First 1
    if (-not $hit) {
        throw "磁盘配置中未找到已启用的 OneBot(aiocqhttp) 端口 $WsPort，请重新执行 OneBot 衔接。"
    }
    Write-Ok ("磁盘配置已确认: id={0} type=aiocqhttp port={1}" -f $hit.id, $WsPort)
}

function Wait-AstrBotOneBotListening {
    param(
        [int]$WsPort,
        [int]$TimeoutSec = 90
    )

    Write-Step "等待 AstrBot OneBot 反向 WS 端口 $WsPort 监听"
    if (-not (Wait-TcpPortOpen -HostName '127.0.0.1' -Port $WsPort -TimeoutSec $TimeoutSec -Label "OneBot :$WsPort")) {
        $logPath = Join-Path (Get-AstrBotDataDir) 'logs\backend.log'
        if (Test-Path $logPath) {
            Write-Warn '最近 backend.log 片段:'
            Get-Content $logPath -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        }
        throw "AstrBot 未在端口 $WsPort 监听 OneBot。请打开「机器人」页确认存在 OneBot，或查看日志。"
    }
    Write-Ok "OneBot 反向 WebSocket 已监听: ws://127.0.0.1:$WsPort/ws"
}

function Write-ScanProgressLine {
    <#
    .SYNOPSIS
      单行回写扫描进度（不换行刷屏）。
    #>
    param(
        [string]$Text,
        [switch]$Finish
    )
    # 固定较短宽度，避免占满整行/整屏
    $width = 72
    try {
        $buf = [Console]::BufferWidth
        if ($buf -gt 20) {
            $width = [Math]::Min(72, $buf - 2)
        }
    } catch {}

    if ($Finish) {
        # 清掉当前进度行后换行，留给后续正常日志
        Write-Host ("`r" + (' ' * $width) + "`r") -NoNewline
        Write-Host ''
        return
    }

    if ($Text.Length -gt $width) {
        $keep = [Math]::Max(8, $width - 3)
        $Text = '...' + $Text.Substring($Text.Length - $keep)
    }
    $pad = ' ' * [Math]::Max(0, $width - $Text.Length)
    Write-Host ("`r{0}{1}" -f $Text, $pad) -NoNewline -ForegroundColor DarkCyan
}

function Find-FileRecurseWithProgress {
    <#
    .SYNOPSIS
      在多个根目录中按文件名递归搜索；进度仅占用一行实时刷新。
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [Parameter(Mandatory = $true)][string[]]$FileNames,
        [int]$MaxHits = 1,
        [int]$UiRefreshEvery = 5
    )

    $skipDirNames = @(
        'Windows', 'WinSxS', 'node_modules', '.git', 'Packages', 'INetCache',
        'Temp', 'tmp', 'Cache', 'Caches', 'npm-cache', '__pycache__',
        'Microsoft Edge', 'Google', 'Mozilla', 'CrashDumps'
    )
    $skipSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $skipDirNames) { [void]$skipSet.Add($n) }

    $validRoots = @(
        $Roots |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
            Select-Object -Unique
    )
    if ($validRoots.Count -eq 0) {
        Write-Warn '没有可扫描的根目录。'
        return @()
    }

    $hits = New-Object System.Collections.Generic.List[string]
    $dirsScanned = 0
    $filesChecked = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cursorWasVisible = $true
    try {
        $cursorWasVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $false
    } catch {}

    try {
        for ($rootIndex = 0; $rootIndex -lt $validRoots.Count; $rootIndex++) {
            $root = $validRoots[$rootIndex]
            $queue = New-Object System.Collections.Generic.Queue[string]
            $queue.Enqueue($root)

            while ($queue.Count -gt 0) {
                $dir = $queue.Dequeue()
                $dirsScanned++

                if (($dirsScanned % $UiRefreshEvery) -eq 0 -or $queue.Count -eq 0) {
                    $elapsed = [int]$sw.Elapsed.TotalSeconds
                    # 路径放后面，超长时优先保留路径尾部
                    $prefix = '扫描 {0}/{1} 目录:{2} 待扫:{3} {4}s ' -f `
                        ($rootIndex + 1), $validRoots.Count, $dirsScanned, $queue.Count, $elapsed
                    Write-ScanProgressLine -Text ($prefix + $dir)
                }

                foreach ($name in $FileNames) {
                    $filesChecked++
                    $candidate = Join-Path $dir $name
                    if (Test-Path -LiteralPath $candidate) {
                        try {
                            $full = [System.IO.Path]::GetFullPath($candidate)
                        } catch {
                            $full = $candidate
                        }
                        if (-not ($hits -contains $full)) {
                            $hits.Add($full) | Out-Null
                            if ($hits.Count -ge $MaxHits) {
                                return [string[]]@($hits.ToArray())
                            }
                        }
                    }
                }

                try {
                    foreach ($child in [System.IO.Directory]::EnumerateDirectories($dir)) {
                        $leaf = [System.IO.Path]::GetFileName($child)
                        if ($skipSet.Contains($leaf)) { continue }
                        $queue.Enqueue($child)
                    }
                }
                catch {
                    # 无权限/已删除目录：跳过
                }
            }

            if ($hits.Count -ge $MaxHits) { break }
        }
    }
    finally {
        Write-ScanProgressLine -Finish
        try { [Console]::CursorVisible = $cursorWasVisible } catch {}
        Write-Detail ("扫描结束：目录 {0} 个，检查 {1} 次，耗时 {2:N1}s，命中 {3}" -f `
                $dirsScanned, $filesChecked, $sw.Elapsed.TotalSeconds, $hits.Count)
    }

    return [string[]]@($hits.ToArray())
}

function Find-AstrBotExecutable {
    Write-Detail '正在搜索 AstrBot 可执行文件 ...'
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\AstrBot\AstrBot.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AstrBot\astrbot-desktop-tauri.exe'),
        (Join-Path $env:LOCALAPPDATA 'AstrBot\AstrBot.exe'),
        (Join-Path $env:LOCALAPPDATA 'AstrBot\astrbot-desktop-tauri.exe'),
        (Join-Path ${env:ProgramFiles} 'AstrBot\AstrBot.exe'),
        (Join-Path ${env:ProgramFiles} 'AstrBot\astrbot-desktop-tauri.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'AstrBot\AstrBot.exe')
    )
    if ($script:DefaultInstallRoot) {
        $candidates += (Join-Path $script:DefaultInstallRoot 'AstrBot\AstrBot.exe')
        $candidates += (Join-Path $script:DefaultInstallRoot 'AstrBot\astrbot-desktop-tauri.exe')
    }

    $i = 0
    foreach ($p in $candidates) {
        $i++
        Write-Detail "[$i/$($candidates.Count)] 检查: $p"
        if ($p -and (Test-Path $p)) {
            Write-Status -State 'OK' -Text "命中 AstrBot 可执行文件: $p"
            return $p
        }
    }

    Write-Detail '常规路径未命中，检查开始菜单快捷方式...'
    $shortcuts = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\AstrBot.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AstrBot.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AstrBot.lnk')
    )
    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnk in $shortcuts) {
        Write-Detail "检查快捷方式: $lnk"
        if (Test-Path $lnk) {
            try {
                $target = $shell.CreateShortcut($lnk).TargetPath
                Write-Detail "快捷方式目标: $target"
                if ($target -and (Test-Path $target)) {
                    Write-Status -State 'OK' -Text "通过快捷方式找到: $target"
                    return $target
                }
            }
            catch {
                Write-Detail "读取快捷方式失败: $($_.Exception.Message)"
            }
        }
    }

    Write-Status -State 'RUN' -Text '常规路径未命中，开始在常见安装目录中递归搜索（会实时显示扫描进度）...'
    $fileNames = @('astrbot-desktop-tauri.exe', 'AstrBot.exe')

    # 先扫高概率目录，命中即停
    $priorityRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'AstrBot'),
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)}
    )
    if ($script:DefaultInstallRoot) { $priorityRoots = @($script:DefaultInstallRoot) + $priorityRoots }

    $hits = Find-FileRecurseWithProgress -Roots $priorityRoots -FileNames $fileNames -MaxHits 1 -UiRefreshEvery 2
    if (-not $hits -or $hits.Count -eq 0) {
        Write-Status -State 'WAIT' -Text '高概率目录未命中，扩大到整个 LocalAppData 继续扫描...'
        $hits = Find-FileRecurseWithProgress -Roots @($env:LOCALAPPDATA) -FileNames $fileNames -MaxHits 1 -UiRefreshEvery 2
    }

    if ($hits -and $hits.Count -gt 0) {
        Write-Status -State 'OK' -Text "递归搜索命中: $($hits[0])"
        return $hits[0]
    }
    Write-Status -State 'FAIL' -Text '未找到 AstrBot 可执行文件'
    return $null
}

function Get-AstrBotDataDir {
    return (Join-Path $env:USERPROFILE '.astrbot')
}

function Get-AstrBotExistingPaths {
    <#
    .SYNOPSIS
      收集本机已存在的 AstrBot 数据目录与常见相关安装目录（去重）。
    #>
    $candidates = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $full = $Path.Trim().TrimEnd('\')
        if (-not (Test-Path -LiteralPath $full)) { return }
        foreach ($existing in $candidates) {
            if ([string]::Equals($existing, $full, [StringComparison]::OrdinalIgnoreCase)) { return }
        }
        $candidates.Add($full) | Out-Null
    }

    & $add (Get-AstrBotDataDir)
    & $add (Join-Path $env:LOCALAPPDATA 'Programs\AstrBot')
    & $add (Join-Path $env:LOCALAPPDATA 'AstrBot')
    & $add (Join-Path ${env:ProgramFiles} 'AstrBot')
    & $add (Join-Path ${env:ProgramFiles(x86)} 'AstrBot')

    if ($script:DefaultInstallRoot) {
        & $add (Join-Path $script:DefaultInstallRoot 'AstrBot')
    }

    try {
        $state = Get-DeployState
        if ($state -is [hashtable]) {
            if ($state['AstrBotDataDir']) { & $add ([string]$state['AstrBotDataDir']) }
            if ($state['AstrBotInstallDir']) { & $add ([string]$state['AstrBotInstallDir']) }
            if ($state['InstallRoot']) { & $add (Join-Path ([string]$state['InstallRoot']) 'AstrBot') }
        }
    }
    catch {}

    return [string[]]@($candidates.ToArray())
}

function Resolve-AstrBotExistingData {
    <#
    .SYNOPSIS
      检测到已有 AstrBot 数据/相关目录时，询问删除或保留（默认推荐删除）。
    #>
    param([switch]$DryRun)

    $dataDir = Get-AstrBotDataDir
    # 强制展平，避免单元素返回值在 StrictMode / @() 下变成嵌套数组
    $paths = @()
    foreach ($item in @(Get-AstrBotExistingPaths)) {
        if ($item -is [System.Array]) {
            foreach ($inner in $item) {
                if (-not [string]::IsNullOrWhiteSpace([string]$inner)) {
                    $paths += [string]$inner
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$item)) {
            $paths += [string]$item
        }
    }
    if (@($paths).Count -eq 0) {
        Write-Detail "尚未发现 AstrBot 数据或相关目录（数据目录预期: $dataDir）"
        Merge-DeployState @{ AstrBotDataResolved = 'none' } | Out-Null
        return 'none'
    }

    Write-Warn '检测到本机已有 AstrBot 数据或相关目录（可能来自旧部署，易导致登录/配置冲突）：'
    foreach ($p in $paths) {
        $tag = if ([string]::Equals($p, $dataDir, [StringComparison]::OrdinalIgnoreCase)) {
            '数据目录'
        }
        else {
            '相关目录'
        }
        Write-Warn ("  [{0}] {1}" -f $tag, $p)
    }
    Write-Warn '建议优先删除后全新部署；若需沿用旧账号/模型/适配器配置再选择保留。'

    if ($DryRun) {
        Write-Info 'DryRun：仅报告，不询问删除/保留，也不执行清理。'
        Merge-DeployState @{ AstrBotDataResolved = 'dryrun_detected' } | Out-Null
        return 'dryrun_detected'
    }

    $choice = Read-UserChoice `
        -Prompt '请选择: d=删除旧数据及相关目录(推荐) / k=保留原有配置并继续' `
        -ValidChoices @('d', 'k') `
        -Default 'd'

    if ($choice -eq 'k') {
        Write-Warn '已选择保留原有配置。将尽量复用；如遇冲突请重新部署并选择删除。'
        Merge-DeployState @{
            AstrBotDataResolved = 'kept'
            AstrBotDataDir      = $dataDir
        } | Out-Null
        return 'kept'
    }

    Write-SubStep -Current 1 -Total 2 -Text '停止 AstrBot 相关进程以便清理'
    [void](Stop-AstrBotProcesses -GraceSec 1)

    Write-SubStep -Current 2 -Total 2 -Text '删除已检测到的 AstrBot 数据及相关目录'
    $removed = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        try {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                $removed.Add($p) | Out-Null
                Write-Ok "已删除: $p"
            }
        }
        catch {
            $failed.Add($p) | Out-Null
            Write-Warn "删除失败: $p — $($_.Exception.Message)"
        }
    }

    if ($failed.Count -gt 0) {
        Write-Warn '部分目录未能删除。可关闭占用程序后重试，或手动清理后再部署。'
        Merge-DeployState @{
            AstrBotDataResolved = 'delete_partial'
            AstrBotDataCleared  = @($removed)
            AstrBotDataFailed   = @($failed)
        } | Out-Null
        return 'delete_partial'
    }

    Write-Ok '旧 AstrBot 数据及相关目录已清理完毕，将按全新环境继续部署。'
    Merge-DeployState @{
        AstrBotDataResolved = 'deleted'
        AstrBotDataCleared  = @($removed)
        AstrBotDataDir      = $dataDir
        AstrBotExe          = $null
        AstrBotInstallDir   = $null
    } | Out-Null
    return 'deleted'
}

function Install-AstrBotDesktop {
    Write-Step '安装 AstrBot 桌面版（可见安装，非静默）'

    Write-SubStep -Current 1 -Total 5 -Text '检查是否已安装 AstrBot'
    $existing = Find-AstrBotExecutable
    if ($existing) {
        Write-Ok "检测到已安装 AstrBot: $existing"
        Write-Detail '跳过安装程序，直接复用现有版本。'
        Merge-DeployState @{
            AstrBotExe     = $existing
            AstrBotDataDir = (Get-AstrBotDataDir)
        } | Out-Null
        return $existing
    }

    Write-SubStep -Current 2 -Total 5 -Text '定位安装包并准备安装目录'
    $setup = Get-PackagePath -FileName 'AstrBot_4.26.8_windows_amd64_setup.exe'
    $setupItem = Get-Item $setup
    Write-Detail "安装包: $setup"
    Write-Detail "大小: $([math]::Round($setupItem.Length/1MB,1)) MB | 版本信息: $($setupItem.VersionInfo.ProductVersion)"

    $installDir = Join-Path $script:DefaultInstallRoot 'AstrBot'
    Assert-AsciiPreferredPath -Path $installDir
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Write-Detail "建议安装目录: $installDir"

    Write-SubStep -Current 3 -Total 5 -Text '启动 AstrBot 安装向导（图形界面）'
    Write-Info '已取消静默安装：将弹出 AstrBot 安装窗口。'
    Write-Info '请在安装向导中确认安装路径等选项，完成后回到本控制台继续。'
    Write-Host ''
    Write-Host '>>> 即将打开 AstrBot 安装程序，请按窗口提示完成安装 <<<' -ForegroundColor Yellow
    Write-Host ''

    # 不使用 /S。可选传入 /D= 作为默认目录提示（部分 NSIS 在非静默下仍尊重）
    $argList = @("/D=$installDir")
    Write-Detail "启动命令: `"$setup`" $($argList -join ' ')"
    $p = Start-Process -FilePath $setup -ArgumentList $argList -PassThru
    $exitCode = Wait-VisibleProcess -Process $p -DisplayName 'AstrBot 安装向导' -HeartbeatSec 3

    if ($exitCode -ne 0) {
        Write-Warn "安装向导退出码为 $exitCode，继续检测是否其实已安装成功..."
    }

    Write-SubStep -Current 4 -Total 5 -Text '校验安装结果'
    Start-Sleep -Seconds 1
    $exe = Find-AstrBotExecutable
    if (-not $exe) {
        foreach ($guessName in @('astrbot-desktop-tauri.exe', 'AstrBot.exe')) {
            $guess = Join-Path $installDir $guessName
            Write-Detail "尝试猜测路径: $guess"
            if (Test-Path $guess) { $exe = $guess; break }
        }
    }
    if (-not $exe) {
        Write-Status -State 'FAIL' -Text '安装后仍未找到 AstrBot.exe'
        throw 'AstrBot 安装后未找到 AstrBot.exe，请确认安装向导是否已成功完成。'
    }

    Write-SubStep -Current 5 -Total 5 -Text '写入部署状态'
    Write-Ok "AstrBot 安装完成: $exe"
    Write-Detail "数据目录预计: $(Get-AstrBotDataDir)"
    Merge-DeployState @{
        AstrBotExe        = $exe
        AstrBotDataDir    = (Get-AstrBotDataDir)
        AstrBotInstallDir = $installDir
        AstrBotSetupExit  = $exitCode
    } | Out-Null
    return $exe
}

function Start-AstrBotApp {
    param(
        [string]$ExePath,
        [int]$DashboardPort = 6185,
        [int]$TimeoutSec = 180
    )

    Write-Step '启动 AstrBot 并等待网关面板就绪'
    if (-not $ExePath) {
        $ExePath = (Get-DeployState).AstrBotExe
    }
    if (-not $ExePath -or -not (Test-Path $ExePath)) {
        throw '未找到 AstrBot 可执行文件。'
    }

    Write-SubStep -Current 1 -Total 3 -Text "检查进程 / 启动应用: $ExePath"
    Merge-DeployState @{ AstrBotExe = $ExePath } | Out-Null
    $running = @(Get-AstrBotProcesses)
    if (@($running).Count -eq 0) {
        Write-Status -State 'RUN' -Text '正在启动 AstrBot 桌面版...'
        Start-Process -FilePath $ExePath | Out-Null
        Start-Sleep -Seconds 2
        $running = @(Get-AstrBotProcesses)
        if (@($running).Count -gt 0) {
            Write-Status -State 'OK' -Text ("AstrBot 进程已启动，PID={0}" -f (($running | Select-Object -ExpandProperty Id) -join ','))
        }
        else {
            Write-Warn '尚未检测到 AstrBot 进程（含 astrbot-desktop-tauri），将继续等待端口就绪。'
        }
    }
    else {
        Write-Status -State 'OK' -Text ("AstrBot 已在运行，PID={0}" -f (($running | Select-Object -ExpandProperty Id) -join ','))
    }

    Write-SubStep -Current 2 -Total 3 -Text "等待仪表盘端口 $DashboardPort"
    if (-not (Test-TcpPortFree -Port $DashboardPort)) {
        Write-Detail "端口 $DashboardPort 当前被占用，可能已是 AstrBot，继续探测连通性。"
    }

    if (-not (Wait-TcpPortOpen -HostName '127.0.0.1' -Port $DashboardPort -TimeoutSec $TimeoutSec -Label "AstrBot 仪表盘 :$DashboardPort")) {
        Write-SubStep -Current 3 -Total 3 -Text '尝试从配置文件读取实际端口'
        $cfg = Join-Path (Get-AstrBotDataDir) 'data\cmd_config.json'
        Write-Detail "配置文件路径: $cfg"
        if (Test-Path $cfg) {
            try {
                $json = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
                $DashboardPort = [int]$json.dashboard.port
                Write-Info "配置文件中的仪表盘端口为 $DashboardPort，继续等待..."
                if (-not (Wait-TcpPortOpen -HostName '127.0.0.1' -Port $DashboardPort -TimeoutSec 60 -Label "AstrBot 仪表盘 :$DashboardPort")) {
                    throw "AstrBot 仪表盘端口 $DashboardPort 未在超时内就绪。"
                }
            }
            catch {
                throw "AstrBot 仪表盘未就绪: $($_.Exception.Message)"
            }
        }
        else {
            throw "AstrBot 仪表盘端口 $DashboardPort 未就绪，且尚未生成配置文件。"
        }
    }
    else {
        Write-SubStep -Current 3 -Total 3 -Text '端口已就绪'
    }

    $url = "http://127.0.0.1:$DashboardPort"
    Merge-DeployState @{
        AstrBotDashboardPort = $DashboardPort
        AstrBotDashboardUrl  = $url
    } | Out-Null
    Write-Ok "AstrBot 网关面板已就绪: $url"
    Write-Detail "可在浏览器打开上述地址验证面板是否可访问。"
    return $DashboardPort
}
