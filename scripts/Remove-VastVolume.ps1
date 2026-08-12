[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
if ($null -eq $state.volume_id) { throw 'State contains no volume_id.' }
if ($state.volume_status -eq 'deleted') { throw 'The tracked volume has already been deleted.' }
if ($state.instance_status -ne 'destroyed' -and $null -ne $state.instance_id) {
    throw 'Destroy the attached instance before deleting its volume.'
}

if (-not $Force) {
    $confirmation = Read-Host "Deleting volume $($state.volume_id) permanently removes models and outputs. Type DELETE-VOLUME"
    if ($confirmation -cne 'DELETE-VOLUME') { throw 'Volume deletion cancelled.' }
}

Invoke-VastText -Config $config -Arguments @('delete', 'volume', [string]$state.volume_id, '--raw') | Out-Host
$state.volume_status = 'deleted'
$state.volume_deleted_at = (Get-Date).ToUniversalTime().ToString('o')
Save-DeploymentState -Config $config -State $state | Out-Null
Write-Host "Volume $($state.volume_id) was permanently deleted." -ForegroundColor Yellow
