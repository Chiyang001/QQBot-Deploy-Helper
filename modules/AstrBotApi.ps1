#Requires -Version 5.1

function Get-AstrBotBaseUrl {
    param([int]$Port = 0)
    if ($Port -le 0) {
        $state = Get-DeployState
        if ($state.AstrBotDashboardPort) {
            $Port = [int]$state.AstrBotDashboardPort
        }
        else {
            $Port = 6185
        }
    }
    return "http://127.0.0.1:$Port"
}

function Invoke-AstrBotApi {
    param(
        [string]$Method = 'GET',
        [string]$Path,
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [int]$Port = 0,
        [int]$TimeoutSec = 60
    )

    $base = Get-AstrBotBaseUrl -Port $Port
    $url = "$base$Path"
    Write-Detail "API $Method $url"
    $params = @{
        Uri             = $url
        Method          = $Method
        TimeoutSec      = $TimeoutSec
        UseBasicParsing = $true
        Headers         = @{}
    }

    foreach ($k in $Headers.Keys) {
        $params.Headers[$k] = $Headers[$k]
    }

    if ($null -ne $Body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $jsonBody = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.Body = $jsonBody
        # 避免把完整 API Key 打到控制台
        $safe = $jsonBody -replace '("key"\s*:\s*\[\s*")[^"]+', '$1***'
        $safe = $safe -replace '("password"\s*:\s*")[^"]+', '$1***'
        $safe = $safe -replace '("new_password"\s*:\s*")[^"]+', '$1***'
        $safe = $safe -replace '("confirm_password"\s*:\s*")[^"]+', '$1***'
        $safe = $safe -replace '("api_key"\s*:\s*")[^"]+', '$1***'
        Write-Detail "请求体: $safe"
    }

    try {
        Write-Status -State 'RUN' -Text "请求中: $Method $Path"
        $resp = Invoke-WebRequest @params
        $text = $resp.Content
        Write-Status -State 'OK' -Text ("响应 HTTP {0}，长度 {1}" -f $resp.StatusCode, $(if ($text) { $text.Length } else { 0 }))
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @{ status = 'ok'; raw = ''; code = $resp.StatusCode }
        }
        try {
            $obj = ($text | ConvertFrom-Json)
            $preview = ($text.Substring(0, [Math]::Min(240, $text.Length))) -replace '\s+', ' '
            Write-Detail "响应预览: $preview"
            return $obj
        }
        catch {
            return @{ status = 'ok'; raw = $text; code = $resp.StatusCode }
        }
    }
    catch {
        $detail = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
        }
        if (-not $detail -and $_.Exception -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object IO.StreamReader($stream)
                    $detail = $reader.ReadToEnd()
                }
            }
            catch {}
        }
        if (-not $detail) { $detail = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '无响应内容（可能尚未完成首次账号初始化/setup）' }
        throw "AstrBot API 调用失败 [$Method $Path]: $detail"
    }
}

function Get-AstrBotSetupStatus {
    param([int]$Port = 0)

    foreach ($path in @('/api/v1/auth/setup-status', '/api/auth/setup-status')) {
        try {
            $st = Invoke-AstrBotApi -Method GET -Path $path -Port $Port
            $data = Get-JsonProperty -Object $st -Name 'data' -Default $st
            return [pscustomobject]@{
                Raw                     = $st
                SetupRequired           = [bool](Get-JsonProperty -Object $data -Name 'setup_required' -Default $false)
                SkipDefaultPasswordAuth = [bool](Get-JsonProperty -Object $data -Name 'skip_default_password_auth' -Default $false)
                PasswordUpgradeRequired = [bool](Get-JsonProperty -Object $data -Name 'password_upgrade_required' -Default $false)
            }
        }
        catch {
            Write-Info "读取 setup-status 失败 ($path): $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Raw                     = $null
        SetupRequired           = $false
        SkipDefaultPasswordAuth = $false
        PasswordUpgradeRequired = $false
    }
}

function Initialize-AstrBotFirstSetup {
    param([int]$Port = 0)

    Write-Step '首次初始化 AstrBot 网关账号（setup）'
    Write-Info '当前 AstrBot 处于首次设置状态：不能使用默认 astrbot/astrbot 直接登录。'
    Write-Info '请现在设置面板用户名和新密码（密码至少 8 位，且含大写、小写、数字）。'

    $username = 'astrbot'
    $inputUser = Read-Host '请设置用户名（直接回车使用 astrbot）'
    if (-not [string]::IsNullOrWhiteSpace($inputUser)) {
        $username = $inputUser.Trim()
    }
    if ($username.Length -lt 3) {
        throw '用户名长度至少 3 位'
    }

    $password = $null
    while ($true) {
        $password = Read-SecurePlainText -Prompt '请设置新密码'
        $confirm = Read-SecurePlainText -Prompt '请再次确认新密码'
        if ($password -ne $confirm) {
            Write-Warn '两次输入不一致，请重试。'
            continue
        }
        $err = Test-DashboardPasswordComplexity -Password $password
        if ($err) {
            Write-Warn $err
            continue
        }
        break
    }

    $body = @{
        username         = $username
        password         = $password
        confirm_password = $password
    }

    $lastError = $null
    foreach ($path in @('/api/v1/auth/setup', '/api/auth/setup', '/api/auth/setup-authenticated')) {
        try {
            $resp = Invoke-AstrBotApi -Method POST -Path $path -Body $body -Port $Port
            if ((Get-JsonProperty -Object $resp -Name 'status') -eq 'error') {
                $lastError = ($resp | ConvertTo-Json -Compress)
                continue
            }

            $token = Get-AstrBotTokenFromResponse -Response $resp

            if (-not $token) {
                # setup 成功但未直接返回 token 时，立刻用新账号登录
                foreach ($loginPath in @('/api/v1/auth/login', '/api/auth/login')) {
                    try {
                        $loginResp = Invoke-AstrBotApi -Method POST -Path $loginPath -Body @{
                            username = $username
                            password = $password
                        } -Port $Port
                        $token = Get-AstrBotTokenFromResponse -Response $loginResp
                        if ($token) { break }
                    }
                    catch {
                        $lastError = $_.Exception.Message
                    }
                }
            }

            if ($token) {
                Merge-DeployState @{
                    AstrBotToken           = $token
                    AstrBotUsername        = $username
                    AstrBotPasswordChanged = $true
                    AstrBotSetupCompleted  = $true
                } | Out-Null
                Write-Ok "AstrBot 首次账号初始化完成（用户: $username）。"
                return $token
            }
            $lastError = ($resp | ConvertTo-Json -Compress)
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw "AstrBot 首次 setup 失败: $lastError"
}

function Get-AuthHeader {
    param([string]$Token)
    return @{ Authorization = "Bearer $Token" }
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-AstrBotTokenFromResponse {
    param([object]$Response)
    $data = Get-JsonProperty -Object $Response -Name 'data'
    $token = Get-JsonProperty -Object $data -Name 'token'
    if (-not $token) { $token = Get-JsonProperty -Object $Response -Name 'token' }
    if ($token) { return [string]$token }
    return $null
}

function Connect-AstrBotDashboard {
    param(
        [string]$Username = 'astrbot',
        [string]$Password = 'astrbot',
        [int]$Port = 0,
        [switch]$PromptIfNeeded,
        [switch]$AllowMissing
    )

    Write-Step '连接 AstrBot 网关（不设置/不修改密码）'

    $status = Get-AstrBotSetupStatus -Port $Port
    if ($status.Raw) {
        Write-Info "setup-status: $($status.Raw | ConvertTo-Json -Compress)"
    }
    if ($status.SetupRequired) {
        Write-Info '检测到 setup_required，按部署策略跳过改密/初始化向导，优先写配置文件完成衔接。'
    }

    # 仅尝试默认账号自动登录；不再弹窗让用户设密/改密
    if ([string]::IsNullOrWhiteSpace($Password)) {
        $Password = 'astrbot'
    }
    if ([string]::IsNullOrWhiteSpace($Username)) {
        $Username = 'astrbot'
    }

    $loginPaths = @('/api/v1/auth/login', '/api/auth/login')
    $lastError = $null
    foreach ($path in $loginPaths) {
        try {
            $resp = Invoke-AstrBotApi -Method POST -Path $path -Body @{
                username = $Username
                password = $Password
            } -Port $Port
            $token = Get-AstrBotTokenFromResponse -Response $resp
            if ($token) {
                Merge-DeployState @{
                    AstrBotToken           = $token
                    AstrBotUsername        = $Username
                    AstrBotPasswordChanged = $false
                    AstrBotSetupCompleted  = $false
                } | Out-Null
                Write-Ok "已使用默认账号登录 AstrBot（$Username）。不会要求修改密码。"
                return $token
            }
            $lastError = ($resp | ConvertTo-Json -Compress)
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    Write-Warn "默认账号自动登录不可用，将改用本地配置文件方式继续部署。原因: $lastError"
    Merge-DeployState @{
        AstrBotToken           = ''
        AstrBotUsername        = $Username
        AstrBotPasswordChanged = $false
        AstrBotUseConfigFile   = $true
    } | Out-Null

    if ($AllowMissing -or (-not $PromptIfNeeded)) {
        return ''
    }

    # PromptIfNeeded 仅在显式要求时保留兼容，默认部署流程不会走到这里
    throw "AstrBot 登录失败（已禁用改密流程）: $lastError"
}

function Ensure-AstrBotAccountReady {
    param([int]$Port = 0)

    Write-Info '初次安装不设置、不修改 AstrBot 密码。'
    $token = Connect-AstrBotDashboard -Username 'astrbot' -Password 'astrbot' -Port $Port -AllowMissing
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Ok '已跳过密码相关步骤，后续将通过配置文件完成 OneBot/模型衔接。'
    }
    else {
        Write-Ok 'AstrBot 已连接，跳过所有改密步骤。'
    }
    return $token
}

function Test-DashboardPasswordComplexity {
    param([string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 8) {
        return '密码长度至少 8 位'
    }
    if ($Password -notmatch '[A-Z]') { return '密码需包含至少 1 个大写字母' }
    if ($Password -notmatch '[a-z]') { return '密码需包含至少 1 个小写字母' }
    if ($Password -notmatch '\d') { return '密码需包含至少 1 个数字' }
    return $null
}

function Update-AstrBotPassword {
    param(
        [string]$Token,
        [string]$OldPassword = 'astrbot',
        [int]$Port = 0
    )

    Write-Step '修改 AstrBot 网关面板密码（首次登录必须修改）'
    Write-Info '密码要求：至少 8 位，且同时包含大写字母、小写字母和数字。'
    Write-Info '初始默认账号/密码一般为: astrbot / astrbot'

    $newPwd = $null
    while ($true) {
        $newPwd = Read-SecurePlainText -Prompt '请设置新密码'
        $confirm = Read-SecurePlainText -Prompt '请再次确认新密码'
        if ($newPwd -ne $confirm) {
            Write-Warn '两次输入不一致，请重试。'
            continue
        }
        $err = Test-DashboardPasswordComplexity -Password $newPwd
        if ($err) {
            Write-Warn $err
            continue
        }
        break
    }

    $newUser = Read-Host '可选：设置新用户名（直接回车保留 astrbot）'
    $body = @{
        password         = $OldPassword
        new_password     = $newPwd
        confirm_password = $newPwd
    }
    if (-not [string]::IsNullOrWhiteSpace($newUser)) {
        $body.new_username = $newUser.Trim()
    }

    $paths = @(
        @{ Method = 'PATCH'; Path = '/api/v1/auth/account' },
        @{ Method = 'POST'; Path = '/api/auth/account/edit' },
        @{ Method = 'POST'; Path = '/api/auth/setup' }
    )

    $ok = $false
    $lastError = $null
    foreach ($p in $paths) {
        try {
            $headers = Get-AuthHeader -Token $Token
            # setup 接口字段略有不同
            $payload = $body
            if ($p.Path -eq '/api/auth/setup' -or $p.Path -eq '/api/v1/auth/setup') {
                $payload = @{
                    username         = $(if ($body.new_username) { $body.new_username } else { 'astrbot' })
                    password         = $newPwd
                    confirm_password = $newPwd
                }
            }
            $resp = Invoke-AstrBotApi -Method $p.Method -Path $p.Path -Headers $headers -Body $payload -Port $Port
            if ($resp.status -eq 'ok' -or $resp.status -eq 0 -or $null -eq $resp.status -or $resp.message) {
                $ok = $true
                Write-Ok "密码修改成功（接口 $($p.Path)）。"
                break
            }
            $lastError = ($resp | ConvertTo-Json -Compress)
        }
        catch {
            $lastError = $_.Exception.Message
            # 若旧密码不对，允许用户重新输入旧密码再试一次
            if ($lastError -match '原密码') {
                $OldPassword = Read-SecurePlainText -Prompt '原密码错误，请输入当前密码'
                $body.password = $OldPassword
            }
        }
    }

    if (-not $ok) {
        throw "修改 AstrBot 密码失败: $lastError"
    }

    # 用新密码重新登录拿 token
    $loginUser = if ($body.new_username) { $body.new_username } else { 'astrbot' }
    Start-Sleep -Seconds 1
    $newToken = $null
    foreach ($path in @('/api/v1/auth/login', '/api/auth/login')) {
        try {
            $resp = Invoke-AstrBotApi -Method POST -Path $path -Body @{
                username = $loginUser
                password = $newPwd
            } -Port $Port
            if ($resp.data.token) { $newToken = [string]$resp.data.token; break }
            if ($resp.token) { $newToken = [string]$resp.token; break }
        }
        catch {}
    }
    if (-not $newToken) {
        Write-Warn '密码已修改，但自动重新登录失败，请稍后手动登录面板确认。'
        return $Token
    }

    Merge-DeployState @{
        AstrBotToken    = $newToken
        AstrBotUsername = $loginUser
        AstrBotPasswordChanged = $true
    } | Out-Null
    Write-Ok '已使用新密码重新登录。'
    return $newToken
}

function New-AstrBotOneBotAdapter {
    param(
        [string]$Token,
        [int]$WsPort,
        [int]$Port = 0
    )

    Write-Step "在 AstrBot 中创建 OneBot v11 反向 WebSocket 服务端（端口 $WsPort，无 Token）"

    # 本机 NapCat 对接用 127.0.0.1，避免部分 Windows 上 0.0.0.0 触发 getaddrinfo failed
    $config = @{
        id               = 'napcat'
        type             = 'aiocqhttp'
        enable           = $true
        ws_reverse_host  = '127.0.0.1'
        ws_reverse_port  = $WsPort
        ws_reverse_token = ''
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Info '无 AstrBot 登录令牌（已跳过改密），直接写入配置文件。'
        Set-AstrBotPlatformInConfigFile -WsPort $WsPort
        return
    }

    $headers = Get-AuthHeader -Token $Token
    $payloads = @(
        @{
            Method = 'POST'
            Path   = '/api/v1/bots'
            Body   = @{
                id     = 'napcat'
                type   = 'aiocqhttp'
                enable = $true
                config = $config
            }
        },
        @{
            Method = 'POST'
            Path   = '/api/config/platform/new'
            Body   = $config
        }
    )

    $lastError = $null
    foreach ($p in $payloads) {
        try {
            $resp = Invoke-AstrBotApi -Method $p.Method -Path $p.Path -Headers $headers -Body $p.Body -Port $Port
            if ($resp.status -eq 'error') {
                $lastError = ($resp | ConvertTo-Json -Compress)
                continue
            }
            Write-Ok 'AstrBot OneBot 适配器配置成功。'
            Merge-DeployState @{ AstrBotOneBotConfigured = $true } | Out-Null
            return
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    Write-Warn "API 创建适配器失败，回退写入配置文件。原因: $lastError"
    Set-AstrBotPlatformInConfigFile -WsPort $WsPort
}

function Set-AstrBotPlatformInConfigFile {
    param([int]$WsPort)

    $cfgPath = Join-Path (Get-AstrBotDataDir) 'data\cmd_config.json'
    if (-not (Test-Path $cfgPath)) {
        throw "未找到 AstrBot 配置文件: $cfgPath （请先成功启动一次 AstrBot）"
    }

    $json = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # 强制数组，避免单元素被 ConvertTo-Json 写成对象导致 AstrBot 无法加载
    $platforms = New-Object System.Collections.ArrayList
    if ($json.platform) {
        foreach ($p in @($json.platform)) {
            if ($p.id -eq 'napcat' -or $p.type -eq 'aiocqhttp') { continue }
            [void]$platforms.Add($p)
        }
    }
    [void]$platforms.Add([pscustomobject]@{
            id               = 'napcat'
            type             = 'aiocqhttp'
            enable           = $true
            ws_reverse_host  = '127.0.0.1'
            ws_reverse_port  = [int]$WsPort
            ws_reverse_token = ''
        })
    $json | Add-Member -NotePropertyName platform -NotePropertyValue @($platforms.ToArray()) -Force

    # 关闭白名单，避免小白部署后收不到消息
    if ($json.platform_settings) {
        $json.platform_settings.enable_id_white_list = $false
    }

    $backup = "$cfgPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $cfgPath $backup -Force
    Write-JsonFile -Path $cfgPath -InputObject $json -Depth 20
    Assert-AstrBotPlatformOnDisk -WsPort $WsPort
    Write-Ok "已写入 AstrBot 配置文件（备份: $backup）"
    Write-Detail "反向 WebSocket: 主机=127.0.0.1 端口=$WsPort Token=空；NapCat 应对接 ws://127.0.0.1:$WsPort/ws"
    Merge-DeployState @{ AstrBotOneBotConfigured = $true; AstrBotConfigBackup = $backup } | Out-Null
}

function New-AstrBotModelProvider {
    param(
        [string]$Token,
        [ValidateSet('openai', 'anthropic')]
        [string]$InterfaceType,
        [string]$ApiKey,
        [string]$ModelName,
        [string]$ApiBase = '',
        [int]$Port = 0
    )

    Write-Step '写入 AstrBot 模型提供商配置'

    if ($InterfaceType -eq 'openai') {
        $type = 'openai_chat_completion'
        if ([string]::IsNullOrWhiteSpace($ApiBase)) { $ApiBase = 'https://api.openai.com/v1' }
    }
    else {
        $type = 'anthropic_chat_completion'
        if ([string]::IsNullOrWhiteSpace($ApiBase)) { $ApiBase = 'https://api.anthropic.com/v1' }
    }

    $providerId = 'user_default_llm'
    $config = @{
        id            = $providerId
        type          = $type
        provider_type = 'chat_completion'
        enable        = $true
        key           = @($ApiKey)
        api_base      = $ApiBase
        timeout       = 120
        model_config  = @{
            model = $ModelName
        }
        model         = $ModelName
    }

    $created = $false
    $lastError = $null

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Info '无 AstrBot 登录令牌（已跳过改密），直接写入模型配置文件。'
        Set-AstrBotProviderInConfigFile -Config $config -ProviderId $providerId
        $created = $true
    }
    else {
        $headers = Get-AuthHeader -Token $Token
        $payloads = @(
            @{
                Method = 'POST'
                Path   = '/api/v1/providers'
                Body   = @{
                    id     = $providerId
                    enable = $true
                    config = $config
                }
            },
            @{
                Method = 'POST'
                Path   = '/api/config/provider/new'
                Body   = $config
            }
        )

        foreach ($p in $payloads) {
            try {
                $resp = Invoke-AstrBotApi -Method $p.Method -Path $p.Path -Headers $headers -Body $p.Body -Port $Port
                if ($resp.status -eq 'error') {
                    $lastError = ($resp | ConvertTo-Json -Compress)
                    continue
                }
                $created = $true
                Write-Ok '模型提供商已创建。'
                break
            }
            catch {
                $lastError = $_.Exception.Message
            }
        }

        if (-not $created) {
            Write-Warn "API 创建提供商失败，回退写入配置文件。原因: $lastError"
            Set-AstrBotProviderInConfigFile -Config $config -ProviderId $providerId
            $created = $true
        }
    }

    # 设为默认 provider
    try {
        Set-AstrBotDefaultProvider -ProviderId $providerId
    }
    catch {
        Write-Warn "设置默认模型提供商失败: $($_.Exception.Message)"
    }

    Merge-DeployState @{
        ProviderId      = $providerId
        ProviderType    = $type
        ProviderModel   = $ModelName
        ProviderApiBase = $ApiBase
    } | Out-Null

    return $providerId
}

function Set-AstrBotProviderInConfigFile {
    param(
        [hashtable]$Config,
        [string]$ProviderId
    )

    $cfgPath = Join-Path (Get-AstrBotDataDir) 'data\cmd_config.json'
    if (-not (Test-Path $cfgPath)) {
        throw "未找到 AstrBot 配置文件: $cfgPath"
    }
    $json = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    if ($json.provider) {
        $list = @($json.provider | Where-Object { $_.id -ne $ProviderId })
    }
    $list += ($Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    $json.provider = $list
    if (-not $json.provider_settings) {
        $json | Add-Member -NotePropertyName provider_settings -NotePropertyValue (@{ enable = $true }) -Force
    }
    $json.provider_settings.enable = $true
    $json.provider_settings.default_provider_id = $ProviderId

    $backup = "$cfgPath.bak_provider_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $cfgPath $backup -Force
    Write-JsonFile -Path $cfgPath -InputObject $json -Depth 20
    Write-Ok "已写入模型配置到 cmd_config.json（备份: $backup）"
}

function Set-AstrBotDefaultProvider {
    param([string]$ProviderId)
    $cfgPath = Join-Path (Get-AstrBotDataDir) 'data\cmd_config.json'
    if (-not (Test-Path $cfgPath)) { return }
    $json = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.provider_settings) { return }
    $json.provider_settings.default_provider_id = $ProviderId
    $json.provider_settings.enable = $true
    Write-JsonFile -Path $cfgPath -InputObject $json -Depth 20
}

function Test-AstrBotProvider {
    param(
        [string]$Token,
        [string]$ProviderId,
        [string]$InterfaceType,
        [string]$ApiKey,
        [string]$ModelName,
        [string]$ApiBase,
        [int]$Port = 0
    )

    Write-Step '校验模型配置（连通性测试）'

    # 有令牌时优先走 AstrBot 内置 test 接口；无令牌则直接测上游 API
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers = Get-AuthHeader -Token $Token
        foreach ($path in @(
                "/api/v1/providers/$ProviderId/test",
                '/api/v1/providers/test'
            )) {
            try {
                $body = if ($path -eq '/api/v1/providers/test') { @{ provider_id = $ProviderId; id = $ProviderId } } else { $null }
                $resp = Invoke-AstrBotApi -Method POST -Path $path -Headers $headers -Body $body -Port $Port -TimeoutSec 90
                if ($resp.status -eq 'error') {
                    Write-Warn "AstrBot 测试接口返回错误: $($resp | ConvertTo-Json -Compress)"
                    continue
                }
                Write-Ok 'AstrBot 内置模型测试通过。'
                return $true
            }
            catch {
                Write-Info "内置测试接口不可用 ($path): $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Info '无 AstrBot 令牌，改为直接测试上游模型接口。'
    }

    # 直接对上游 API 做最小请求校验
    try {
        if ($InterfaceType -eq 'openai') {
            if ([string]::IsNullOrWhiteSpace($ApiBase)) { $ApiBase = 'https://api.openai.com/v1' }
            $url = ($ApiBase.TrimEnd('/')) + '/chat/completions'
            $payload = @{
                model    = $ModelName
                messages = @(@{ role = 'user'; content = 'ping' })
                max_tokens = 8
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-WebRequest -Uri $url -Method POST -Headers @{
                Authorization = "Bearer $ApiKey"
            } -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 60 -UseBasicParsing
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                Write-Ok 'OpenAI 兼容接口连通性测试通过。'
                return $true
            }
            throw "HTTP $($resp.StatusCode): $($resp.Content)"
        }
        else {
            if ([string]::IsNullOrWhiteSpace($ApiBase)) { $ApiBase = 'https://api.anthropic.com/v1' }
            $url = ($ApiBase.TrimEnd('/')) + '/messages'
            # 兼容用户填写的 base 是否已含 /v1
            if ($ApiBase -match '/v1/?$') {
                $url = ($ApiBase.TrimEnd('/')) + '/messages'
            }
            elseif ($ApiBase -notmatch '/messages$') {
                $url = ($ApiBase.TrimEnd('/')) + '/v1/messages'
            }
            $payload = @{
                model      = $ModelName
                max_tokens = 16
                messages   = @(@{ role = 'user'; content = 'ping' })
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-WebRequest -Uri $url -Method POST -Headers @{
                'x-api-key'         = $ApiKey
                'anthropic-version' = '2023-06-01'
            } -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 60 -UseBasicParsing
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                Write-Ok 'Anthropic 兼容接口连通性测试通过。'
                return $true
            }
            throw "HTTP $($resp.StatusCode): $($resp.Content)"
        }
    }
    catch {
        Write-Err "模型连通性测试失败: $($_.Exception.Message)"
        return $false
    }
}
