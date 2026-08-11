[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Security.SecureString]$ApiKey,
    [switch]$IgnoreEnvironment
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$cli = [string]$config.Vast.Cli
Assert-CommandExists -Name $cli

if ($null -eq $ApiKey) {
    $envName = [string]$config.Secrets.VastApiKeyEnvironmentVariable
    $envValue = if ($IgnoreEnvironment) { $null } else { [Environment]::GetEnvironmentVariable($envName) }
    if ($envValue) {
        $ApiKey = ConvertTo-SecureString -String $envValue -AsPlainText -Force
    }
    else {
        Write-Host ''
        Write-Host 'Vast CLI 登录向导' -ForegroundColor Cyan
        Write-Host '请粘贴 Vast.ai API key；输入内容不会显示。' -ForegroundColor Cyan
        $ApiKey = Read-Host "Vast API key（也可预先设置 $envName）" -AsSecureString
    }
}

$credential = New-Object System.Management.Automation.PSCredential('vast', $ApiKey)
$plainKey = $credential.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($plainKey)) { throw 'Vast API key 不能为空。' }
try {
    $result = Invoke-NativeCommandCapture -Command $cli -Arguments @('set', 'api-key', $plainKey)
    if ($result.ExitCode -ne 0) {
        throw "vastai set api-key failed: $($result.Text)"
    }
}
finally {
    $plainKey = $null
}

Invoke-VastText -Config $config -Arguments @('show', 'user') | Out-Host
Write-Host 'Vast CLI authentication is configured.' -ForegroundColor Green
