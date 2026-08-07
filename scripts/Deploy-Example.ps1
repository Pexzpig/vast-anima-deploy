[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'config.psd1' }

& (Join-Path $PSScriptRoot 'New-VastDeployment.ps1') -ConfigPath $ConfigPath -Force:$Force
& (Join-Path $PSScriptRoot 'Provision-Instance.ps1') -ConfigPath $ConfigPath

Write-Host ''
Write-Host 'Deployment and provisioning completed.' -ForegroundColor Green
Write-Host 'Run .\scripts\Open-ComfyUITunnel.ps1, then open the printed local URL.'
