[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Security.SecureString]$ApiKey
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$cli = [string]$config.Vast.Cli
Assert-CommandExists -Name $cli

if ($null -eq $ApiKey) {
    $envName = [string]$config.Secrets.VastApiKeyEnvironmentVariable
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if ($envValue) {
        $ApiKey = ConvertTo-SecureString -String $envValue -AsPlainText -Force
    }
    else {
        $ApiKey = Read-Host "Enter Vast API key (or set $envName)" -AsSecureString
    }
}

$credential = New-Object System.Management.Automation.PSCredential('vast', $ApiKey)
$plainKey = $credential.GetNetworkCredential().Password
try {
    $output = & $cli set api-key $plainKey 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "vastai set api-key failed: $($output -join "`n")"
    }
}
finally {
    $plainKey = $null
}

Invoke-VastText -Config $config -Arguments @('show', 'user') | Out-Host
Write-Host 'Vast CLI authentication is configured.' -ForegroundColor Green
