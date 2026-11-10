#Requires -Version 5.1

function Resolve-OneBotWsPort {
    <#
    .SYNOPSIS
      按官方文档优先 6199，占用则 6200 → 6201，再取其他空闲端口。
    #>
    param([int]$PreferredPort = 6199)

    $preferred = @($PreferredPort, 6200, 6201) | Select-Object -Unique
    foreach ($p in $preferred) {
        $free = Test-TcpPortFree -Port $p
        Write-Detail ("探测端口 {0}: {1}" -f $p, $(if ($free) { '可用' } else { '占用' }))
        if ($free) { return $p }
    }

    Write-Warn '6199/6200/6201 均不可用，继续寻找其他空闲端口...'
    $port = Find-FreeTcpPort -StartPort 6202 -MaxTries 80
    return $port
}

function Initialize-OneBotBridge {
    param(
        [string]$Token,
        [string]$NapCatDir,
        [int]$PreferredPort = 6199,
        [int]$DashboardPort = 0
    )

    Write-Title 'OneBot 端口衔接'

    Write-SubStep -Current 1 -Total 4 -Text '先停止 AstrBot，避免运行中覆盖磁盘配置'
    # 运行中的 AstrBot 退出时可能把内存里的旧配置写回磁盘，冲掉刚写入的 platform
    [void](Stop-AstrBotProcesses -GraceSec 2 -EnsureStopped)
    Start-Sleep -Seconds 1

    Write-SubStep -Current 2 -Total 4 -Text '检测/分配反向 WebSocket 端口（优先 6199）'
    $port = Resolve-OneBotWsPort -PreferredPort $PreferredPort
    Write-Ok "使用 OneBot 反向 WebSocket 端口: $port"
    Write-Info "AstrBot 作为反向 WS 服务端；NapCat 作为客户端连接 ws://127.0.0.1:$port/ws"

    Write-SubStep -Current 3 -Total 4 -Text '配置 AstrBot OneBot 适配器（不设置反向 WS Token）'
    New-AstrBotOneBotAdapter -Token $Token -WsPort $port -Port $DashboardPort

    Write-SubStep -Current 4 -Total 4 -Text '配置 NapCat WebSocket 客户端（地址含 /ws，自动重连）'
    New-NapCatOneBotConfig -NapCatDir $NapCatDir -AstrBotWsPort $port

    $wsUrl = "ws://127.0.0.1:$port/ws"
    Merge-DeployState @{
        OneBotWsPort = $port
        OneBotToken  = ''
        OneBotWsUrl  = $wsUrl
    } | Out-Null

    Write-Ok "衔接完成: NapCat -> $wsUrl"
    Write-Info 'AstrBot: 反向 WebSocket 主机 127.0.0.1 / 端口如上；无需 Token。'
    Write-Info 'NapCat: 写入 napcat\config\onebot11_<QQ>.json 的 WebSockets 客户端（等同 WebUI 新建）。'
    Write-Info 'AstrBot 已保持停止；扫码与模型配置完成后会统一启动并校验 OneBot。'
    return $port
}
