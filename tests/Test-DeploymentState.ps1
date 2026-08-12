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

$resumable = [pscustomobject]@{
    instance_id = $null
    instance_status = 'create_failed'
    volume_id = 47510939
    volume_status = 'created'
}
if (-not (Test-DeploymentStateCanResumeInstance -State $resumable)) {
    throw 'A failed instance creation with an existing volume was not resumable.'
}
if (Test-DeploymentStateCanResumeInstance -State $retainedVolume) {
    throw 'A retained volume from a destroyed instance was incorrectly resumable.'
}

$continueDeployment = [pscustomobject]@{
    instance_id = 47511276
    instance_status = 'created'
    provisioned = $false
}
if (-not (Test-DeploymentStateCanContinueDeployment -State $continueDeployment)) {
    throw 'A created but unprovisioned instance could not continue deployment.'
}
$continueDeployment.provisioned = $true
if (Test-DeploymentStateCanContinueDeployment -State $continueDeployment) {
    throw 'An already provisioned instance was incorrectly resumable.'
}

$singleInstanceResponse = [pscustomobject]@{
    instances = [pscustomobject]@{ id = 47511276; actual_status = 'running' }
}
$singleInstanceItems = @(ConvertTo-ObjectArray -Value $singleInstanceResponse -CandidateProperties @('instances'))
if ($singleInstanceItems.Count -ne 1 -or $singleInstanceItems[0].id -ne 47511276) {
    throw 'A single Vast instance response was not normalized to a one-item array.'
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

# A start request is asynchronous. The first show-instance response can still
# contain the previous exited state, so one stale sample must not abort startup.
$script:instanceStatusResponses = [System.Collections.Queue]::new()
$script:instanceStatusResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 47511276
        actual_status = 'exited'
        intended_status = 'running'
        cur_state = 'stopped'
        next_state = 'running'
        status_msg = $null
    }
})
$script:instanceStatusResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 47511276
        actual_status = 'loading'
        intended_status = 'running'
        cur_state = 'running'
        next_state = 'running'
        status_msg = $null
    }
})
$script:instanceStatusResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 47511276
        actual_status = 'running'
        intended_status = 'running'
        cur_state = 'running'
        next_state = 'running'
        status_msg = $null
    }
})

function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments)

    if ($script:instanceStatusResponses.Count -eq 0) {
        throw 'The startup wait requested more mocked responses than expected.'
    }
    return $script:instanceStatusResponses.Dequeue()
}

$waitConfig = @{
    Vast = @{
        Instance = @{
            WaitTimeoutSeconds = 5
            PollIntervalSeconds = 0
        }
    }
}
$runningInstance = Wait-VastInstanceRunning -Config $waitConfig -InstanceId 47511276
if ($runningInstance.actual_status -ne 'running' -or $script:instanceStatusResponses.Count -ne 0) {
    throw 'An exited/loading/running startup sequence was not allowed to complete.'
}

$script:instanceStatusResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 47511276
        actual_status = 'exited'
        intended_status = 'running'
        cur_state = 'running'
        next_state = 'running'
        status_msg = 'container entrypoint failed'
    }
})
$persistentExitCaught = $false
try {
    Wait-VastInstanceRunning -Config $waitConfig -InstanceId 47511276 -TerminalStateGraceSeconds 0 | Out-Null
}
catch {
    $persistentExitCaught = $true
    if ($_.Exception.Message -notmatch 'container entrypoint failed' -or
        $_.Exception.Message -notmatch 'vastai logs 47511276') {
        throw "A persistent exit did not include actionable diagnostics: $($_.Exception.Message)"
    }
}
if (-not $persistentExitCaught) {
    throw 'A persistent exited state was incorrectly accepted as running.'
}

Write-Host 'Deployment-state recovery and price formatting passed.' -ForegroundColor Green
