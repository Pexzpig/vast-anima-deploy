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

$choiceRows = @(ConvertTo-VastOfferChoiceRows -Offers @(
    [pscustomobject]@{
        id = 25318187
        gpu_name = 'RTX 6000Ada'
        gpu_ram = 49140
        dph_total = 0.5907222222
        reliability2 = 0.9970279
        inet_down = 851.4
        machine_id = 33732
    },
    [pscustomobject]@{
        id = 24964768
        gpu_name = 'L40S'
        gpu_ram = 46068
        dph_total = 0.6009259259
        reliability2 = 0.9980183
        inet_down = 587.6
        machine_id = 41600
    }
))
if ($choiceRows.Count -ne 2 -or
    $choiceRows[0].choice -ne 1 -or
    $choiceRows[0].price_USD_hour -ne '$0.5907' -or
    $choiceRows[1].choice -ne 2 -or
    $choiceRows[1].offer_id -ne 24964768) {
    throw 'GPU offer choices were not numbered or priced correctly.'
}

Write-Host 'Deployment-state recovery and price formatting passed.' -ForegroundColor Green
