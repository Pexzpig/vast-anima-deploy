[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$incomplete = [pscustomobject]@{
    instance_id = $null
    instance_status = 'pending'
    volume_id = $null
    volume_status = 'pending'
}
if (Test-DeploymentStateHasActiveResources -State $incomplete) {
    throw 'A local pending record without remote resource IDs was treated as active.'
}

$activeInstance = [pscustomobject]@{
    instance_id = 123
    instance_status = 'running'
    volume_id = $null
    volume_status = 'disabled'
}
if (-not (Test-DeploymentStateHasActiveResources -State $activeInstance)) {
    throw 'A running remote instance was not treated as active.'
}

$retainedVolume = [pscustomobject]@{
    instance_id = 123
    instance_status = 'destroyed'
    volume_id = 456
    volume_status = 'created'
}
if (-not (Test-DeploymentStateHasActiveResources -State $retainedVolume)) {
    throw 'A retained remote volume was not treated as active.'
}

$cleanedUp = [pscustomobject]@{
    instance_id = 123
    instance_status = 'destroyed'
    volume_id = 456
    volume_status = 'deleted'
}
if (Test-DeploymentStateHasActiveResources -State $cleanedUp) {
    throw 'Destroyed/deleted remote resources were treated as active.'
}

if ((Format-UsdPrice -Amount 0.5907222222) -ne '$0.5907') {
    throw 'USD price formatting is not stable or invariant.'
}

Write-Host 'Deployment-state recovery and price formatting passed.' -ForegroundColor Green
