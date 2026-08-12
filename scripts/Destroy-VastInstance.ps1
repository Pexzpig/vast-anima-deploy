[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
if ($null -eq $state.instance_id) { throw 'State contains no instance_id.' }
if ($state.instance_status -eq 'destroyed') { throw 'The tracked instance has already been destroyed.' }

if (-not $Force) {
    $confirmation = Read-Host "Destroying instance $($state.instance_id) is irreversible. Type DESTROY"
    if ($confirmation -cne 'DESTROY') { throw 'Destroy cancelled.' }
}

Invoke-VastText -Config $config -Arguments @('destroy', 'instance', [string]$state.instance_id, '--raw') | Out-Host
$state.instance_status = 'destroyed'
$state.destroyed_at = (Get-Date).ToUniversalTime().ToString('o')
Save-DeploymentState -Config $config -State $state | Out-Null
if ($null -ne $state.volume_id -and [string]$state.volume_status -ne 'deleted') {
    Write-Host "Instance $($state.instance_id) was destroyed. Separately created volume $($state.volume_id) is retained." -ForegroundColor Yellow
} else {
    Write-Host "Instance $($state.instance_id) was destroyed. It had no persistent volume; its instance-disk data is permanently lost." -ForegroundColor Yellow
}
