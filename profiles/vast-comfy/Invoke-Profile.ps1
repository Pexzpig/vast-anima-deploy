[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Initialize', 'Test', 'Search', 'Deploy', 'Provision', 'Tunnel', 'Status', 'Start', 'Stop', 'Destroy', 'RemoveVolume')]
    [string]$Action = 'Deploy',
    [switch]$Force,
    [Security.SecureString]$ApiKey
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scriptRoot = Join-Path $projectRoot 'scripts'
$configPath = Join-Path $PSScriptRoot 'config.psd1'

Write-Host "Using vastai/comfy profile: $configPath" -ForegroundColor Cyan

switch ($Action) {
    'Initialize' {
        $arguments = @{ ConfigPath = $configPath }
        if ($null -ne $ApiKey) { $arguments.ApiKey = $ApiKey }
        & (Join-Path $scriptRoot 'Initialize-Vast.ps1') @arguments
    }
    'Test' { & (Join-Path $scriptRoot 'Test-Configuration.ps1') -ConfigPath $configPath }
    'Search' { & (Join-Path $scriptRoot 'Search-VastOffers.ps1') -ConfigPath $configPath }
    'Deploy' {
        & (Join-Path $scriptRoot 'Initialize-Environment.ps1') -ConfigPath $configPath | Out-Host
        & (Join-Path $scriptRoot 'Deploy-Example.ps1') -ConfigPath $configPath -Force:$Force
    }
    'Provision' { & (Join-Path $scriptRoot 'Provision-Instance.ps1') -ConfigPath $configPath }
    'Tunnel' { & (Join-Path $scriptRoot 'Open-ComfyUITunnel.ps1') -ConfigPath $configPath }
    'Status' { & (Join-Path $scriptRoot 'Get-DeploymentStatus.ps1') -ConfigPath $configPath }
    'Start' { & (Join-Path $scriptRoot 'Start-VastInstance.ps1') -ConfigPath $configPath }
    'Stop' { & (Join-Path $scriptRoot 'Stop-VastInstance.ps1') -ConfigPath $configPath }
    'Destroy' { & (Join-Path $scriptRoot 'Destroy-VastInstance.ps1') -ConfigPath $configPath -Force:$Force }
    'RemoveVolume' { & (Join-Path $scriptRoot 'Remove-VastVolume.ps1') -ConfigPath $configPath -Force:$Force }
}
