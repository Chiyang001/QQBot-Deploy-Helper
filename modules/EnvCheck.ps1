#Requires -Version 5.1

function Test-VcRuntimeInstalled {
    Write-Detail '检查 VC++ x64 注册表标记...'
    $markers = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($key in $markers) {
        Write-Detail "注册表: $key"
        if (Test-Path $key) {
            try {
                $installed = (Get-ItemProperty -Path $key -ErrorAction Stop).Installed
                Write-Detail "Installed=$installed"
                if ($installed -eq 1) { return $true }
            }
            catch {
                Write-Detail "读取失败: $($_.Exception.Message)"
            }
        }
    }

    Write-Detail '检查 System32 关键 DLL...'
    $system32 = Join-Path $env:WINDIR 'System32'
    $dlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
    foreach ($dll in $dlls) {
        $path = Join-Path $system32 $dll
        $exists = Test-Path $path
        Write-Detail ("{0}: {1}" -f $dll, $(if ($exists) { '存在' } else { '缺失' }))
        if (-not $exists) {
            return $false
        }
    }
    return $true
}

function Install-VcRedistIfNeeded {
    param([switch]$Force)

    Write-Step '检查 Visual C++ 运行库'
    Write-SubStep -Current 1 -Total 3 -Text '检测是否已安装 VC++ x64'
    $needInstall = $Force -or -not (Test-VcRuntimeInstalled)

    if (-not $needInstall) {
        Write-Ok '已检测到 VC++ x64 运行库。'
        return $false
    }

    Write-SubStep -Current 2 -Total 3 -Text '准备运行 VC_redist.x64.exe（可见安装）'
    Write-Warn '缺少 VC++ x64 运行库或关键 DLL，将启动官方安装程序...'
    $vc = Get-PackagePath -FileName 'VC_redist.x64.exe'
    Write-Detail "安装包: $vc ($([math]::Round((Get-Item $vc).Length/1MB,1)) MB)"
    if (-not (Test-IsAdmin)) {
        Write-Warn '当前未以管理员身份运行，VC 运行库安装可能失败。建议右键“以管理员身份运行”一键部署.bat。'
    }

    # 不使用 /quiet：弹出安装界面；/passive 仅进度条，这里改为完整可见安装
    Write-Info '已取消静默参数。将弹出 VC_redist 安装窗口，请按提示完成。'
    Write-Detail '启动参数: /install /norestart'
    $p = Start-Process -FilePath $vc -ArgumentList @('/install', '/norestart') -PassThru
    $code = Wait-VisibleProcess -Process $p -DisplayName 'VC_redist.x64' -HeartbeatSec 2

    Write-SubStep -Current 3 -Total 3 -Text '核验安装结果'
    if ($code -in 0, 1638, 3010) {
        Write-Ok "VC_redist.x64.exe 安装完成（退出码 $code）。"
        if ($code -eq 1638) { Write-Detail '1638 = 已安装更新版本' }
        if ($code -eq 3010) { Write-Detail '3010 = 成功但需要重启（通常可继续）' }
        $ok = Test-VcRuntimeInstalled
        Write-Status -State $(if ($ok) { 'OK' } else { 'WAIT' }) -Text ("复检 VC 运行库: {0}" -f $(if ($ok) { '已就绪' } else { '仍未检测到，可稍后重启再试' }))
        return $true
    }

    throw "VC_redist.x64.exe 安装失败，退出码: $code。请手动运行该程序后重试。"
}

function Invoke-EnvironmentCheck {
    param([switch]$DryRun)

    Write-Title '环境检测与准备工作'

    Write-SubStep -Current 1 -Total 6 -Text '读取系统信息'
    $os = Get-CimInstance Win32_OperatingSystem
    $arch = $env:PROCESSOR_ARCHITECTURE
    Write-Info "系统: $($os.Caption) ($($os.Version))"
    Write-Info "架构: $arch"
    Write-Info "用户: $env:USERNAME"
    Write-Info "管理员权限: $(Test-IsAdmin)"
    Write-Detail "计算机名: $env:COMPUTERNAME | PowerShell: $($PSVersionTable.PSVersion)"

    if ($arch -notin @('AMD64', 'x86_64')) {
        throw '本部署包仅支持 Windows x64 (AMD64)。'
    }

    Write-SubStep -Current 2 -Total 6 -Text '检查内存与磁盘'
    $freeGb = [math]::Round(($os.FreePhysicalMemory / 1024.0 / 1024.0), 2)
    Write-Info ("可用内存约: {0} GB" -f $freeGb)
    if ($freeGb -lt 1.5) {
        Write-Warn '可用内存偏低，后续启动 QQ/AstrBot 可能较慢。'
    }

    $systemDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $freeDiskGb = [math]::Round(($systemDrive.Free / 1GB), 2)
    Write-Info ("系统盘剩余空间: {0} GB" -f $freeDiskGb)
    if ($freeDiskGb -lt 3) {
        throw '系统盘剩余空间不足 3GB，请清理磁盘后再部署。'
    }

    Write-SubStep -Current 3 -Total 6 -Text '校验安装包文件'
    $required = @(
        'AstrBot_4.26.8_windows_amd64_setup.exe',
        'VC_redist.x64.exe'
    )
    $ri = 0
    foreach ($name in $required) {
        $ri++
        $path = Get-PackagePath -FileName $name
        Write-Ok "[$ri/$($required.Count)] 安装包就绪: $name ($([math]::Round((Get-Item $path).Length/1MB,1)) MB)"
        Write-Detail $path
    }

    $nodeZip = Join-Path $script:RootDir 'NapCat.Shell.Windows.Node.zip'
    $oneKeyZip = Join-Path $script:RootDir 'NapCat.Shell.Windows.OneKey.zip'
    if (Test-Path -LiteralPath $nodeZip) {
        Write-Ok ("NapCat 安装包就绪(推荐): NapCat.Shell.Windows.Node.zip ({0} MB)" -f [math]::Round((Get-Item $nodeZip).Length / 1MB, 1))
        Write-Detail $nodeZip
    }
    elseif (Test-Path -LiteralPath $oneKeyZip) {
        Write-Warn '未找到 NapCat.Shell.Windows.Node.zip，将使用 OneKey（需联网下载 QQ，CDN 可能 404）。'
        Write-Ok ("NapCat 备用安装包: NapCat.Shell.Windows.OneKey.zip ({0} MB)" -f [math]::Round((Get-Item $oneKeyZip).Length / 1MB, 1))
        Write-Detail $oneKeyZip
    }
    else {
        throw @"
缺少 NapCat 安装包。
请将 NapCat.Shell.Windows.Node.zip（推荐）放到: $script:RootDir
"@
    }

    Write-SubStep -Current 4 -Total 6 -Text '检查 WebView2 / 端口 / 既有安装'
    $webviewKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    $hasWebView = $false
    foreach ($k in $webviewKeys) {
        Write-Detail "WebView2 注册表: $k"
        if (Test-Path $k) { $hasWebView = $true; break }
    }
    if ($hasWebView) {
        Write-Ok '已检测到 Microsoft Edge WebView2。'
    }
    else {
        Write-Warn '未检测到 WebView2。若 AstrBot 桌面版无法打开界面，请安装 Microsoft Edge WebView2 Runtime。'
    }

    foreach ($port in @(6185, 6199, 6099)) {
        if (Test-TcpPortFree -Port $port) {
            Write-Ok "端口 $port 当前可用。"
        }
        else {
            Write-Warn "端口 $port 已被占用，部署时将自动尝试切换到空闲端口。"
        }
    }

    Write-Detail '检查是否存在旧的 AstrBot 数据及相关目录...'
    Resolve-AstrBotExistingData -DryRun:$DryRun | Out-Null

    Write-Info 'NapCat 安装路线：优先 Node 完整包（离线内置 QQNT）；不启用 Framework。'

    Write-SubStep -Current 5 -Total 6 -Text '检查/安装 VC++ 运行库'
    [void](Install-VcRedistIfNeeded)

    Write-SubStep -Current 6 -Total 6 -Text '环境检测汇总'
    Write-Ok '环境检测完成，可以进入安装流程。'
}
