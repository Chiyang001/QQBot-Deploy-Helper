#Requires -Version 5.1

function Invoke-ModelConfigurationWizard {
    param(
        [string]$Token,
        [int]$Port = 0
    )

    Write-Title '大模型接口配置'

    Write-Host '请选择模型接口格式:' -ForegroundColor Cyan
    Write-Host '  1) OpenAI 兼容接口（Chat Completions）'
    Write-Host '  2) Anthropic 兼容接口（Messages）'
    $choice = Read-UserChoice -Prompt '请输入 1 或 2' -ValidChoices @('1', '2')

    $interfaceType = if ($choice -eq '1') { 'openai' } else { 'anthropic' }

    $defaultBase = if ($interfaceType -eq 'openai') {
        'https://api.openai.com/v1'
    }
    else {
        'https://api.anthropic.com/v1'
    }

    Write-Info "接口类型: $interfaceType"
    $apiBase = Read-Host "请输入 API Base URL（直接回车使用默认: $defaultBase）"
    if ([string]::IsNullOrWhiteSpace($apiBase)) { $apiBase = $defaultBase }

    $apiKey = $null
    while ([string]::IsNullOrWhiteSpace($apiKey)) {
        $apiKey = Read-SecurePlainText -Prompt '请输入 API Key'
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Warn 'API Key 不能为空。'
        }
    }

    $modelName = $null
    while ([string]::IsNullOrWhiteSpace($modelName)) {
        $modelName = Read-Host '请输入模型名称（例如 gpt-4o-mini / claude-3-5-sonnet）'
        if ([string]::IsNullOrWhiteSpace($modelName)) {
            Write-Warn '模型名称不能为空。'
        }
    }

    Write-Host ''
    Write-Host '即将校验以下配置:' -ForegroundColor Cyan
    Write-Host "  接口: $interfaceType"
    Write-Host "  Base: $apiBase"
    Write-Host "  模型: $modelName"
    Write-Host "  Key : $($apiKey.Substring(0, [Math]::Min(6, $apiKey.Length)))****"
    $confirm = Read-UserChoice -Prompt '确认无误并开始检测？(y/n)' -ValidChoices @('y', 'n') -Default 'y'
    if ($confirm -ne 'y') {
        throw '用户取消模型配置。请先准备好正确的模型信息后重新运行部署助手。'
    }

    $maxRetry = 5
    for ($i = 1; $i -le $maxRetry; $i++) {
        Write-Info "第 $i/$maxRetry 次配置与校验..."
        $providerId = New-AstrBotModelProvider `
            -Token $Token `
            -InterfaceType $interfaceType `
            -ApiKey $apiKey `
            -ModelName $modelName `
            -ApiBase $apiBase `
            -Port $Port

        $ok = Test-AstrBotProvider `
            -Token $Token `
            -ProviderId $providerId `
            -InterfaceType $interfaceType `
            -ApiKey $apiKey `
            -ModelName $modelName `
            -ApiBase $apiBase `
            -Port $Port

        if ($ok) {
            Write-Ok '模型配置检查通过。下一步将重启 AstrBot 以加载 OneBot 与模型配置。'
            Merge-DeployState @{ ModelConfigured = $true } | Out-Null
            return
        }

        Write-Err '模型配置未通过校验，不能进入下一步。'
        Write-Warn '请检查 API Key、模型名称、Base URL 是否正确，以及网络是否可访问该接口。'
        $again = Read-UserChoice -Prompt '是否重新填写模型信息？(y/n)' -ValidChoices @('y', 'n') -Default 'y'
        if ($again -ne 'y') {
            throw '模型配置未完成。请先完成模型配置后再继续部署。'
        }

        $choice = Read-UserChoice -Prompt '请重新选择接口 1=OpenAI / 2=Anthropic' -ValidChoices @('1', '2') -Default $choice
        $interfaceType = if ($choice -eq '1') { 'openai' } else { 'anthropic' }
        $defaultBase = if ($interfaceType -eq 'openai') { 'https://api.openai.com/v1' } else { 'https://api.anthropic.com/v1' }
        $apiBase = Read-Host "请输入 API Base URL（默认 $defaultBase）"
        if ([string]::IsNullOrWhiteSpace($apiBase)) { $apiBase = $defaultBase }
        $apiKey = Read-SecurePlainText -Prompt '请输入 API Key'
        $modelName = Read-Host '请输入模型名称'
    }

    throw '多次模型校验失败，请确认密钥与网络后重新运行部署助手。'
}
