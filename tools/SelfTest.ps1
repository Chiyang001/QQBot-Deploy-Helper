#Requires -Version 5.1
# 无污染自检：仅验证脚本可加载、安装包存在、端口/运行库检测可用
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

. (Join-Path $root 'modules\Common.ps1')
. (Join-Path $root 'modules\EnvCheck.ps1')
. (Join-Path $root 'modules\InstallAstrBot.ps1')
. (Join-Path $root 'modules\InstallNapCat.ps1')
. (Join-Path $root 'modules\Desktop.ps1')
. (Join-Path $root 'modules\AstrBotApi.ps1')
. (Join-Path $root 'modules\OneBotBridge.ps1')
. (Join-Path $root 'modules\ModelConfig.ps1')

Initialize-DeployWorkspace
Write-Host '== module load OK ==' -ForegroundColor Green

foreach ($n in @(
        'AstrBot_4.26.8_windows_amd64_setup.exe',
        'VC_redist.x64.exe'
    )) {
    $null = Get-PackagePath $n
    Write-Host "OK package: $n" -ForegroundColor Green
}

$nodeZip = Join-Path $root 'NapCat.Shell.Windows.Node.zip'
$oneKeyZip = Join-Path $root 'NapCat.Shell.Windows.OneKey.zip'
if (-not (Test-Path -LiteralPath $nodeZip) -and -not (Test-Path -LiteralPath $oneKeyZip)) {
    throw 'missing NapCat.Shell.Windows.Node.zip (recommended) or OneKey.zip'
}
if (Test-Path -LiteralPath $nodeZip) {
    Write-Host 'OK package: NapCat.Shell.Windows.Node.zip' -ForegroundColor Green
}
if (Test-Path -LiteralPath $oneKeyZip) {
    Write-Host 'OK package: NapCat.Shell.Windows.OneKey.zip' -ForegroundColor Green
}

$p1 = Find-FreeTcpPort -StartPort 6199 -MaxTries 20
Write-Host "OK free port: $p1" -ForegroundColor Green
if (-not (Test-TcpPortFree -Port $p1)) { throw 'Test-TcpPortFree logic error' }

$obPort = Resolve-OneBotWsPort -PreferredPort 6199
if ($obPort -lt 1) { throw 'Resolve-OneBotWsPort failed' }
Write-Host "OK OneBot port resolve: $obPort" -ForegroundColor Green
$null = Get-AstrBotProcesses
Write-Host 'OK Get-AstrBotProcesses callable' -ForegroundColor Green

$vc = Test-VcRuntimeInstalled
Write-Host "VC runtime installed: $vc" -ForegroundColor Cyan

if (Test-Path -LiteralPath $oneKeyZip) {
    $tmp = Join-Path $root '_test_onekey_extract'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-ZipSafe -ZipPath $oneKeyZip -Destination $tmp
    if (-not (Test-Path (Join-Path $tmp 'NapCatInstaller.exe'))) { throw 'OneKey missing NapCatInstaller.exe' }
    if (-not (Test-Path (Join-Path $tmp 'bootmain\napcat.bat'))) { throw 'OneKey missing bootmain\napcat.bat' }
    $boot = Join-Path $tmp 'bootmain'
    if (Test-NapCatRuntimeReady -NapCatDir $boot) {
        throw 'incomplete OneKey bootmain must NOT be treated as ready'
    }
    if (Find-NapCatShellDir -SearchRoot $tmp) {
        throw 'Find-NapCatShellDir must ignore bootmain without QQ.exe'
    }
    Write-Host 'OK OneKey zip structure + incomplete bootmain rejected' -ForegroundColor Green
    Remove-Item -Recurse -Force $tmp
}

if (Test-Path -LiteralPath $nodeZip) {
    $tmpNode = Join-Path $root '_test_node_extract'
    if (Test-Path $tmpNode) { Remove-Item -Recurse -Force $tmpNode }
    Expand-ZipSafe -ZipPath $nodeZip -Destination $tmpNode
    if (-not (Test-NapCatRuntimeReady -NapCatDir $tmpNode)) {
        throw 'Node package extract must be runtime-ready'
    }
    if (-not (Find-NapCatShellDir -SearchRoot $tmpNode)) {
        throw 'Find-NapCatShellDir must recognize Node package'
    }
    Write-Host 'OK Node zip structure + runtime ready' -ForegroundColor Green
    Remove-Item -Recurse -Force $tmpNode
}

Merge-DeployState @{ SelfTest = $true; At = (Get-Date).ToString('s') } | Out-Null
$stObj = Get-DeployState
if (-not $stObj.SelfTest) { throw 'DeployState read/write failed' }
Write-Host 'OK deploy state' -ForegroundColor Green

$err = Test-DashboardPasswordComplexity 'abc'
if (-not $err) { throw 'password policy should fail' }
$err2 = Test-DashboardPasswordComplexity 'Abcdefg1'
if ($err2) { throw "password policy should pass: $err2" }
Write-Host 'OK password policy' -ForegroundColor Green

Write-Orange 'Bingo! orange text preview'

Write-Host ''
Write-Host 'SelfTest ALL PASSED (no AstrBot/NapCat install, env clean).' -ForegroundColor Green
