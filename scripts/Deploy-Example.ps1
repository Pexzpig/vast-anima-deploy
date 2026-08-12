[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [int64]$OfferId = 0
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'config.psd1' }
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-DeployConfig -ConfigPath $ConfigPath
$statePath = Resolve-ProjectPath -Path ([string]$config.Local.StatePath)

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (Test-DeploymentStateCanContinueDeployment -State $existingState) {
        Write-Host "Continuing deployment for existing instance $($existingState.instance_id); no paid resource will be created again." -ForegroundColor Yellow
        if ([string]$existingState.instance_status -eq 'stopped') {
            & (Join-Path $PSScriptRoot 'Start-VastInstance.ps1') -ConfigPath $ConfigPath
        } elseif ([string]$existingState.instance_status -ne 'running') {
            Wait-VastInstanceRunning -Config $config -InstanceId $existingState.instance_id | Out-Null
            $existingState.instance_status = 'running'
            Save-DeploymentState -Config $config -State $existingState | Out-Null
        }
        & (Join-Path $PSScriptRoot 'Provision-Instance.ps1') -ConfigPath $ConfigPath
        Write-Host ''
        Write-Host 'Deployment and provisioning completed.' -ForegroundColor Green
        Write-Host 'Return to Start-VastAnima.ps1 and choose the ComfyUI tunnel, or run it with -Action Tunnel.'
        return
    }
}

$deploymentArguments = @{
    ConfigPath = $ConfigPath
    Force = $Force
}
if ($OfferId -gt 0) { $deploymentArguments.OfferId = $OfferId }
& (Join-Path $PSScriptRoot 'New-VastDeployment.ps1') @deploymentArguments
& (Join-Path $PSScriptRoot 'Provision-Instance.ps1') -ConfigPath $ConfigPath

Write-Host ''
Write-Host 'Deployment and provisioning completed.' -ForegroundColor Green
Write-Host 'Return to Start-VastAnima.ps1 and choose the ComfyUI tunnel, or run it with -Action Tunnel.'
