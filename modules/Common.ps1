#Requires -Version 5.1
Set-StrictMode -Version Latest

# 本文件位于 <Root>\modules\Common.ps1
$script:RootDir = Split-Path -Parent $PSScriptRoot

$script:RuntimeDir = Join-Path $script:RootDir 'runtime'
$script:LogsDir = Join-Path $script:RootDir 'logs'
$script:StateFile = Join-Path $script:RuntimeDir 'deploy_state.json'
$script:DefaultInstallRoot = 'C:\ChiXiaoYangBot'

function Initialize-DeployWorkspace {
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir, $script:LogsDir | Out-Null
}

$script:DeployLogFile = $null

function Write-DeployLog {
    param([string]$Text)
    if (-not $script:DeployLogFile) { return }
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
        Add-Content -Path $script:DeployLogFile -Value $line -Encoding UTF8
    }
    catch {}
}

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-DeployLog ("==== {0} ====" -f $Text)
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    $msg = "[步骤] $Text"
    Write-Host $msg -ForegroundColor Green
    Write-DeployLog $msg
}

function Write-Info {
    param([string]$Text)
    $msg = "[信息] $Text"
    Write-Host $msg -ForegroundColor Gray
    Write-DeployLog $msg
}

function Write-Ok {
    param([string]$Text)
    $msg = "[成功] $Text"
    Write-Host $msg -ForegroundColor Green
    Write-DeployLog $msg
}

function Write-Warn {
    param([string]$Text)
    $msg = "[警告] $Text"
    Write-Host $msg -ForegroundColor Yellow
    Write-DeployLog $msg
}

function Write-Err {
    param([string]$Text)
    $msg = "[错误] $Text"
    Write-Host $msg -ForegroundColor Red
    Write-DeployLog $msg
}

function Write-Orange {
    param([string]$Text)
    $esc = [char]27
    Write-Host ("{0}[38;5;208m{1}{0}[0m" -f $esc, $Text)
    Write-DeployLog $Text
}

function Write-Detail {
    param([string]$Text)
    $msg = "[详情] $Text"
    Write-Host $msg -ForegroundColor DarkCyan
    Write-DeployLog $msg
}

function Write-Status {
    param(
        [string]$Text,
        [ValidateSet('WAIT', 'RUN', 'OK', 'FAIL', 'INFO')]
        [string]$State = 'INFO'
    )
    $color = switch ($State) {
        'WAIT' { 'Yellow' }
        'RUN'  { 'Cyan' }
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    $msg = "[状态:$State] $Text"
    Write-Host $msg -ForegroundColor $color
    Write-DeployLog $msg
}

function Write-SubStep {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Text
    )
    $pct = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }
    $barLen = 20
    $filled = [int]($barLen * $pct / 100)
    if ($filled -gt $barLen) { $filled = $barLen }
    $bar = ('#' * $filled) + ('-' * ($barLen - $filled))
    $msg = "[子进度 $Current/$Total|$pct%|$bar] $Text"
    Write-Host $msg -ForegroundColor Cyan
    Write-DeployLog $msg
}

function Write-ProgressRoadmap {
    <#
    .SYNOPSIS
      打印总览路线图：已完成 / 进行中 / 未开始，方便用户定位当前阶段。
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Titles,
        [Parameter(Mandatory = $true)][int]$CurrentIndex,
        [string]$Header = '部署总览'
    )

    Write-Host ''
    Write-Host ("----- {0} -----" -f $Header) -ForegroundColor DarkYellow
    for ($i = 0; $i -lt $Titles.Count; $i++) {
        $mark = '[ ]'
        $color = 'DarkGray'
        if ($i -lt $CurrentIndex) {
            $mark = '[OK]'
            $color = 'Green'
        }
        elseif ($i -eq $CurrentIndex) {
            $mark = '[>>]'
            $color = 'Yellow'
        }
        $line = ("  {0} {1}/{2}  {3}" -f $mark, ($i + 1), $Titles.Count, $Titles[$i])
        Write-Host $line -ForegroundColor $color
        Write-DeployLog $line
    }
    Write-Host '------------------------------' -ForegroundColor DarkYellow
}

function Start-DeployTranscript {
    Initialize-DeployWorkspace
    $script:DeployLogFile = Join-Path $script:LogsDir ("deploy_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    "==== 炽小阳部署日志 $($script:DeployLogFile) ====" | Set-Content -Path $script:DeployLogFile -Encoding UTF8
    Write-Info "详细日志将写入: $($script:DeployLogFile)"
}

function Wait-VisibleProcess {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [string]$DisplayName = '安装程序',
        [int]$HeartbeatSec = 3
    )

    if ($HeartbeatSec -lt 1) { $HeartbeatSec = 1 }
    Write-Status -State 'RUN' -Text ("正在等待「{0}」完成（PID={1}）" -f $DisplayName, $Process.Id)
    Write-Info '若弹出图形安装/卸载窗口，请在窗口中继续操作；本控制台会每隔几秒报告仍在等待。'
    Write-DeployLog ("Wait process start: {0} pid={1}" -f $DisplayName, $Process.Id)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $nextBeat = $HeartbeatSec
    while (-not $Process.HasExited) {
        Start-Sleep -Milliseconds 500
        try { $Process.Refresh() } catch { break }
        $elapsed = [int]$sw.Elapsed.TotalSeconds
        if ($elapsed -ge $nextBeat) {
            Write-Status -State 'WAIT' -Text ("仍在等待「{0}」... 已等待 {1}s（PID={2}）" -f $DisplayName, $elapsed, $Process.Id)
            $nextBeat += $HeartbeatSec
        }
    }

    $Process.WaitForExit() | Out-Null
    Write-Status -State 'OK' -Text ("「{0}」已结束，退出码={1}，耗时 {2:N1}s" -f $DisplayName, $Process.ExitCode, $sw.Elapsed.TotalSeconds)
    Write-DeployLog ("Wait process end: {0} exit={1}" -f $DisplayName, $Process.ExitCode)
    return $Process.ExitCode
}

function Write-BatchFile {
    <#
    .SYNOPSIS
      写入 .bat/.cmd：UTF-8 无 BOM。
      PowerShell 默认 UTF8 带 BOM 会导致 cmd 认不出首行 @echo off，从而回显整段命令。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $text = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $text = $text.TrimStart()
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text = $text -replace "`n", "`r`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

function Write-JsonFile {
    <#
    .SYNOPSIS
      将对象序列化为 JSON 并写入文件（UTF-8 无 BOM）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 20
    )
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, ($json + "`r`n"), $utf8NoBom)
}

function Read-UserChoice {
    param(
        [string]$Prompt,
        [string[]]$ValidChoices,
        [string]$Default = ''
    )
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) {
            return $Default
        }
        if ($ValidChoices -contains $value) {
            return $value
        }
        Write-Warn "请输入有效选项: $($ValidChoices -join '/')"
    }
}

function Read-SecurePlainText {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TcpPortFree {
    param([int]$Port)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    }
    catch {
        return $false
    }
}

function Find-FreeTcpPort {
    param(
        [int]$StartPort = 6199,
        [int]$MaxTries = 50
    )
    for ($i = 0; $i -lt $MaxTries; $i++) {
        $port = $StartPort + $i
        if (Test-TcpPortFree -Port $port) {
            return $port
        }
    }
    throw "从端口 $StartPort 起连续 $MaxTries 个端口均不可用。"
}

function Wait-TcpPortOpen {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutSec = 120,
        [string]$Label = ''
    )
    if (-not $Label) { $Label = "端口 ${HostName}:${Port}" }
    Write-Status -State 'WAIT' -Text "正在等待 $Label 就绪（最长 ${TimeoutSec}s）..."
    Write-Detail ("探测目标: {0}:{1}" -f $HostName, $Port)
    Write-DeployLog ("Wait port: {0}" -f $Label)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastReport = -5
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($HostName, $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(800, $false)
            if ($ok -and $client.Connected) {
                $client.EndConnect($iar)
                $client.Close()
                Write-Status -State 'OK' -Text ("{0} 已连通（耗时 {1:N1}s）" -f $Label, $sw.Elapsed.TotalSeconds)
                return $true
            }
            $client.Close()
        }
        catch {
            # retry
        }

        $elapsed = [int]$sw.Elapsed.TotalSeconds
        if (($elapsed - $lastReport) -ge 5) {
            $lastReport = $elapsed
            $remain = [Math]::Max(0, $TimeoutSec - $elapsed)
            Write-Status -State 'WAIT' -Text ("仍在等待 {0} ... 已等待 {1}s，剩余约 {2}s" -f $Label, $elapsed, $remain)
        }
        Start-Sleep -Milliseconds 800
    }

    Write-Status -State 'FAIL' -Text "$Label 在 ${TimeoutSec}s 内未就绪"
    return $false
}

function Get-PackagePath {
    param([string]$FileName)
    $path = Join-Path $script:RootDir $FileName
    if (-not (Test-Path $path)) {
        throw "缺少安装包文件: $FileName`n请将其放在: $script:RootDir"
    }
    return $path
}

function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return @{} }
        if ($InputObject -is [hashtable]) { return $InputObject }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $InputObject.Keys) { $h[$k] = $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [pscustomobject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) {
                $val = $p.Value
                if ($val -is [pscustomobject] -or $val -is [System.Collections.IDictionary]) {
                    $h[$p.Name] = ConvertTo-HashtableRecursive $val
                }
                else {
                    $h[$p.Name] = $val
                }
            }
            return $h
        }
        return @{}
    }
}

function Save-DeployState {
    param([hashtable]$State)
    Initialize-DeployWorkspace
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Get-DeployState {
    if (-not (Test-Path $script:StateFile)) {
        return @{}
    }
    $raw = Get-Content -Path $script:StateFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }
    return ConvertTo-HashtableRecursive ($raw | ConvertFrom-Json)
}

function Merge-DeployState {
    param([hashtable]$Patch)
    $state = Get-DeployState
    foreach ($key in $Patch.Keys) {
        $state[$key] = $Patch[$key]
    }
    Save-DeployState -State $state
    return $state
}

function New-RandomToken {
    param([int]$Length = 24)
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Expand-ZipSafe {
    param(
        [string]$ZipPath,
        [string]$Destination
    )
    $zipItem = Get-Item -LiteralPath $ZipPath
    Write-SubStep -Current 1 -Total 3 -Text "准备解压: $($zipItem.Name) ($([math]::Round($zipItem.Length/1MB,1)) MB)"
    Write-Detail "目标目录: $Destination"

    if (Test-Path $Destination) {
        Write-Detail '目标目录已存在，正在清理...'
        Remove-Item -Recurse -Force $Destination
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Write-SubStep -Current 2 -Total 3 -Text ("正在解压「{0}」..." -f $zipItem.Name)
    Write-Info '解压期间控制台可能短暂无新输出，请稍候；完成后会立刻打印结果。'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
    Write-SubStep -Current 3 -Total 3 -Text ("解压完成，耗时 {0:N1}s" -f $sw.Elapsed.TotalSeconds)
    $count = @(Get-ChildItem -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue).Count
    Write-Status -State 'OK' -Text "解压产物约 $count 个文件/文件夹"
}

function Assert-AsciiPreferredPath {
    param([string]$Path)
    if ($Path -match '[^\x00-\x7F]') {
        Write-Warn "路径包含非 ASCII 字符，可能导致 NapCat/QQ 启动异常: $Path"
        Write-Warn "强烈建议安装到纯英文路径（例如 C:\ChiXiaoYangBot）。"
        $choice = Read-UserChoice -Prompt '仍要继续使用该路径吗？(y/n)' -ValidChoices @('y', 'n') -Default 'n'
        if ($choice -ne 'y') {
            throw '用户取消：请改用纯英文安装路径后重试。'
        }
    }
}

function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [int]$TimeoutSec = 0
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch {}
            throw "进程超时未退出: $FilePath"
        }
    }
    else {
        $proc.WaitForExit()
    }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $proc.StandardOutput.ReadToEnd()
        StdErr   = $proc.StandardError.ReadToEnd()
    }
}
