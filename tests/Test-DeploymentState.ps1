[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

function New-ValidDeploymentState {
    return [pscustomobject][ordered]@{
        schema_version = 2
        created_at = '2026-08-12T00:00:00Z'
        updated_at = '2026-08-12T00:00:00Z'
        search_query = 'gpu_name in [RTX_4090]'
        offer_id = 100
        machine_id = 200
        gpu_name = 'RTX_4090'
        hourly_usd = 0.5
        volume_monthly_usd = 0
        estimated_total_hourly_usd = 0.5
        volume_id = $null
        volume_label = $null
        volume_status = 'disabled'
        storage_mode = 'instance_disk'
        application_type = 'comfyui'
        deployment_image = 'vastai/pytorch:cuda-12.8.1-auto'
        instance_id = 300
        instance_status = 'running'
        provisioned = $false
        provisioned_at = $null
        ssh_host = $null
        ssh_port = $null
        last_error = $null
        destroyed_at = $null
        volume_deleted_at = $null
    }
}

$validState = New-ValidDeploymentState
if ((Assert-DeploymentState -State $validState).schema_version -ne 2) {
    throw 'The current deployment-state schema was rejected.'
}

$invalidSchema = New-ValidDeploymentState
$invalidSchema.schema_version = 1
$invalidSchemaRejected = $false
try {
    Assert-DeploymentState -State $invalidSchema | Out-Null
} catch {
    $invalidSchemaRejected = $true
    if ($_.Exception.Message -notmatch 'schema_version') { throw }
}
if (-not $invalidSchemaRejected) { throw 'An obsolete deployment-state schema was accepted.' }

$missingApplication = New-ValidDeploymentState | Select-Object * -ExcludeProperty application_type
$missingApplicationRejected = $false
try {
    Assert-DeploymentState -State $missingApplication | Out-Null
} catch {
    $missingApplicationRejected = $true
    if ($_.Exception.Message -notmatch 'application_type') { throw }
}
if (-not $missingApplicationRejected) { throw 'A deployment state missing application_type was accepted.' }

$invalidStorage = New-ValidDeploymentState
$invalidStorage.storage_mode = 'obsolete'
$invalidStorageRejected = $false
try {
    Assert-DeploymentState -State $invalidStorage | Out-Null
} catch {
    $invalidStorageRejected = $true
    if ($_.Exception.Message -notmatch 'storage_mode') { throw }
}
if (-not $invalidStorageRejected) { throw 'An unsupported storage mode was accepted.' }

$stateTestDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-state-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateTestDirectory | Out-Null
try {
    $stateTestPath = Join-Path $stateTestDirectory 'deployment.json'
    Save-JsonFile -Value (New-ValidDeploymentState) -Path $stateTestPath | Out-Null
    $loadedState = Get-DeploymentState -Config @{ Local = @{ StatePath = $stateTestPath } }
    if ($loadedState.application_type -ne 'comfyui') { throw 'A valid current state could not be loaded.' }
} finally {
    Remove-Item -LiteralPath $stateTestDirectory -Recurse -Force
}

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
$foundInstance = Find-VastInstanceInResponse -Response $singleInstanceResponse -InstanceId 47511276
if ($null -eq $foundInstance -or $foundInstance.id -ne 47511276) {
    throw 'The tracked Vast instance was not found in an account response.'
}
if ($null -ne (Find-VastInstanceInResponse -Response $singleInstanceResponse -InstanceId 99999999)) {
    throw 'A missing Vast instance was incorrectly found in an account response.'
}
if ($null -ne (Find-VastInstanceInResponse -Response $null -InstanceId 47511276)) {
    throw 'An empty Vast instance list was not treated as empty.'
}

function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    return [pscustomobject]@{ success = $false; msg = 'permission denied' }
}
$listErrorCaught = $false
try {
    Get-VastAccountInstance -Config @{} -InstanceId 47511276 | Out-Null
}
catch {
    $listErrorCaught = $true
    if ($_.Exception.Message -notmatch 'reported an error') {
        throw "A Vast list error was misclassified: $($_.Exception.Message)"
    }
}
if (-not $listErrorCaught) {
    throw 'A Vast list error was incorrectly treated as an empty account.'
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
        public_ipaddr = '203.0.113.10'
        geolocation = 'Germany, DE'
        machine_id = 33732
    },
    [pscustomobject]@{
        id = 24964768
        gpu_name = 'L40S'
        gpu_ram = 46068
        dph_total = 0.6009259259
        reliability2 = 0.9980183
        inet_down = 587.6
        public_ipaddr = '198.51.100.20'
        geolocation = 'Türkiye, TR'
        machine_id = 41600
    }
))
if ($choiceRows.Count -ne 2 -or
    $choiceRows[0].choice -ne 1 -or
    $choiceRows[0].price_USD_hour -ne '$0.5907' -or
    $choiceRows[0].ip -ne '203.0.113.10' -or
    $choiceRows[0].region -ne 'Germany, DE' -or
    $choiceRows[1].choice -ne 2 -or
    $choiceRows[1].ip -ne '198.51.100.20' -or
    $choiceRows[1].region -ne 'Türkiye, TR' -or
    $choiceRows[1].PSObject.Properties.Name -contains 'offer_id' -or
    $choiceRows[1].PSObject.Properties.Name -contains 'machine_id') {
    throw 'GPU offer choices did not show IP/region or exposed internal IDs.'
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
