[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [int64]$OfferId = 0
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'config.psd1' }

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
