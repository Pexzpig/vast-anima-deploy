[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [int64]$OfferId = 0
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$volumeConfig = $config.Vast.Volume
$resumeState = $null

$existingStatePath = Resolve-ProjectPath -Path ([string]$config.Local.StatePath)
if (Test-Path -LiteralPath $existingStatePath) {
    $existingState = Get-Content -LiteralPath $existingStatePath -Raw | ConvertFrom-Json
    if (Test-DeploymentStateHasActiveResources -State $existingState) {
        if (Test-DeploymentStateCanResumeInstance -State $existingState) {
            $resumeState = $existingState
            Write-Warning "Resuming instance creation with existing volume $($existingState.volume_id); no new volume will be created."
        } else {
            throw "An active instance or retained volume is already tracked in $existingStatePath. Destroy/delete it first so paid resources are not orphaned."
        }
    } else {
        Write-Warning "Replacing a previous deployment record that has no active remote resources: $existingStatePath"
    }
}

# This is intentionally called on every deployment so the saved scope is
# always re-evaluated against current marketplace offers.
$offers = @(& (Join-Path $PSScriptRoot 'Search-VastOffers.ps1') -ConfigPath $ConfigPath -PassThru -Quiet)
if ($offers.Count -eq 0) { throw 'Search returned no offers.' }

$selectedOffer = $null
$selectedVolumeOffer = $null
$eligibleOffers = @($offers | Where-Object {
    [double](Get-ObjectProperty -Object $_ -Names @('dph_total', 'dph') -Default 999999) -le
        [double]$config.Vast.Search.MaxHourlyUsd
})
if ($null -ne $resumeState) {
    $resumeMachineId = [int64](Get-ObjectProperty -Object $resumeState -Names @('machine_id') -Default 0)
    $eligibleOffers = @($eligibleOffers | Where-Object {
        [int64](Get-ObjectProperty -Object $_ -Names @('machine_id') -Default 0) -eq $resumeMachineId
    })
}
if ($eligibleOffers.Count -eq 0) {
    if ($null -ne $resumeState) {
        throw "No current GPU offer on machine $resumeMachineId can reuse volume $($resumeState.volume_id). Keep the volume and retry later, or delete it before deploying on another machine."
    }
    throw 'No searched GPU offer is within the configured hourly ceiling.'
}
$remainingOffers = @($eligibleOffers)

while ($null -eq $selectedOffer) {
    if ($remainingOffers.Count -eq 0) {
        throw 'None of the selected GPU candidates also satisfied the persistent-volume requirements.'
    }

    Write-Host ''
    Write-Host 'Select a GPU offer for deployment' -ForegroundColor Cyan
    @(ConvertTo-VastOfferChoiceRows -Offers $remainingOffers) | Format-Table -AutoSize | Out-Host

    $offer = $null
    if ($OfferId -gt 0) {
        $offer = @($remainingOffers | Where-Object {
            [int64](Get-ObjectProperty -Object $_ -Names @('id') -Default 0) -eq $OfferId
        } | Select-Object -First 1)[0]
        if ($null -eq $offer) {
            throw "Requested offer ID $OfferId is not in the current eligible search results."
        }
    } else {
        while ($null -eq $offer) {
            $answer = (Read-Host 'Enter the choice number to deploy, or 0 to cancel').Trim()
            $choice = 0
            if (-not [int]::TryParse($answer, [ref]$choice) -or $choice -lt 0 -or $choice -gt $remainingOffers.Count) {
                Write-Warning "Enter a number from 0 to $($remainingOffers.Count)."
                continue
            }
            if ($choice -eq 0) { throw 'Deployment cancelled.' }
            $offer = $remainingOffers[$choice - 1]
        }
    }

    if ($null -ne $resumeState -or -not [bool]$volumeConfig.Enabled) {
        $selectedOffer = $offer
        break
    }

    $machineId = [string](Get-ObjectProperty -Object $offer -Names @('machine_id'))
    if (-not $machineId) {
        throw 'The selected GPU offer did not include a machine ID.'
    }
    $volumeQuery = [string]$volumeConfig.SearchQueryTemplate
    $volumeQuery = $volumeQuery.Replace('{machine_id}', $machineId).Replace('{size_gb}', [string]$volumeConfig.SizeGb)
    try {
        $volumeResponse = Invoke-VastJson -Config $config -Arguments @(
            'search', 'volumes', $volumeQuery, '--raw',
            '--limit', [string]$volumeConfig.SearchLimit,
            '-o', [string]$volumeConfig.SearchOrder,
            '--storage', [string]$volumeConfig.SizeGb
        )
        $volumeOffers = @(ConvertTo-ObjectArray -Value $volumeResponse -CandidateProperties @('offers'))
        if ($volumeOffers.Count -gt 0) {
            $selectedOffer = $offer
            $selectedVolumeOffer = $volumeOffers[0]
            break
        }
    }
    catch {
        throw "Volume search failed for selected machine ${machineId}: $($_.Exception.Message)"
    }

    if ($OfferId -gt 0) {
        throw "Requested offer ID $OfferId has no persistent-volume offer satisfying the configured requirements."
    }
    Write-Warning "The selected GPU on machine $machineId has no matching persistent volume. Choose another offer."
    $selectedId = [int64](Get-ObjectProperty -Object $offer -Names @('id') -Default 0)
    $remainingOffers = @($remainingOffers | Where-Object {
        [int64](Get-ObjectProperty -Object $_ -Names @('id') -Default 0) -ne $selectedId
    })
}

if ($null -eq $selectedOffer) {
    throw 'No matched GPU offer also satisfied the hourly ceiling and volume requirements. Run Start-VastAnima.ps1 -Action Configure to adjust the stored scope.'
}

$offerId = [int64](Get-ObjectProperty -Object $selectedOffer -Names @('id'))
$hourlyPrice = [double](Get-ObjectProperty -Object $selectedOffer -Names @('dph_total', 'dph') -Default 0)
$gpuName = [string](Get-ObjectProperty -Object $selectedOffer -Names @('gpu_name') -Default 'unknown')
$machineId = [int64](Get-ObjectProperty -Object $selectedOffer -Names @('machine_id') -Default 0)

$instanceHourlyText = Format-UsdPrice -Amount $hourlyPrice
$volumeMonthlyUsd = 0.0
$volumeHourlyUsd = 0.0
$estimatedTotalHourlyUsd = $hourlyPrice

Write-Host ''
Write-Host 'Vast.ai deployment price' -ForegroundColor Yellow
Write-Host "  GPU offer: $offerId | $gpuName | machine $machineId"
Write-Host "  Instance: $instanceHourlyText USD/hour"
if ($null -ne $resumeState) {
    $volumeMonthlyUsd = [double](Get-ObjectProperty -Object $resumeState -Names @('volume_monthly_usd') -Default 0)
    $volumeHourlyUsd = $volumeMonthlyUsd / (30 * 24)
    $estimatedTotalHourlyUsd += $volumeHourlyUsd
    Write-Host "  Existing volume: $($resumeState.volume_id) | $($volumeConfig.SizeGb) GB | approximately $(Format-UsdPrice -Amount $volumeMonthlyUsd -Decimals 2) USD/month"
    Write-Host "  Estimated combined rate: $(Format-UsdPrice -Amount $estimatedTotalHourlyUsd) USD/hour"
    Write-Host '  This retry reuses the existing volume and will not create another one.' -ForegroundColor Green
} elseif ($selectedVolumeOffer) {
    $storageUsdPerGbMonth = [double](Get-ObjectProperty -Object $selectedVolumeOffer -Names @('storage_cost') -Default 0)
    $volumeMonthlyUsd = $storageUsdPerGbMonth * [double]$volumeConfig.SizeGb
    $volumeHourlyUsd = $volumeMonthlyUsd / (30 * 24)
    $estimatedTotalHourlyUsd += $volumeHourlyUsd
    Write-Host "  Volume: $($volumeConfig.SizeGb) GB | $(Format-UsdPrice -Amount $storageUsdPerGbMonth) USD/GB/month | approximately $(Format-UsdPrice -Amount $volumeMonthlyUsd -Decimals 2) USD/month"
    Write-Host "  Estimated combined rate: $(Format-UsdPrice -Amount $estimatedTotalHourlyUsd) USD/hour"
    Write-Host '  The persistent volume continues billing after the instance is stopped or destroyed.' -ForegroundColor Yellow
}
Write-Host "  Configured instance ceiling: $(Format-UsdPrice -Amount ([double]$config.Vast.Search.MaxHourlyUsd) -Decimals 2) USD/hour"

if (-not $Force) {
    $confirmation = Read-Host 'This creates paid Vast.ai resources at the prices above. Type RENT to continue'
    if ($confirmation -cne 'RENT') { throw 'Deployment cancelled.' }
}

if ($null -ne $resumeState) {
    $state = $resumeState
    $state.search_query = [string]$config.Vast.Search.Query
    $state.offer_id = $offerId
    $state.machine_id = $machineId
    $state.gpu_name = $gpuName
    $state.hourly_usd = $hourlyPrice
    $state.volume_monthly_usd = $volumeMonthlyUsd
    $state.estimated_total_hourly_usd = $estimatedTotalHourlyUsd
    $state.instance_status = 'pending'
    $state.provisioned = $false
    $state.provisioned_at = $null
    $state.ssh_host = $null
    $state.ssh_port = $null
    $state.last_error = $null
} else {
    $state = [ordered]@{
        schema_version = 1
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        search_query = [string]$config.Vast.Search.Query
        offer_id = $offerId
        machine_id = $machineId
        gpu_name = $gpuName
        hourly_usd = $hourlyPrice
        volume_monthly_usd = $volumeMonthlyUsd
        estimated_total_hourly_usd = $estimatedTotalHourlyUsd
        volume_id = $null
        volume_label = $null
        volume_status = if ([bool]$volumeConfig.Enabled) { 'pending' } else { 'disabled' }
        instance_id = $null
        instance_status = 'pending'
        provisioned = $false
        provisioned_at = $null
        ssh_host = $null
        ssh_port = $null
        last_error = $null
        destroyed_at = $null
        volume_deleted_at = $null
    }
}
Save-DeploymentState -Config $config -State $state | Out-Null

if ([bool]$volumeConfig.Enabled -and $null -eq $resumeState) {
    $volumeOfferId = [int64](Get-ObjectProperty -Object $selectedVolumeOffer -Names @('id'))
    $volumeLabel = '{0}_{1}' -f $volumeConfig.LabelPrefix, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $volumeResponse = Invoke-VastJson -Config $config -Arguments @(
        'create', 'volume', [string]$volumeOfferId,
        '--size', [string]$volumeConfig.SizeGb,
        '--name', $volumeLabel,
        '--raw'
    )
    $state.volume_id = Resolve-CreatedId -Response $volumeResponse
    $state.volume_label = $volumeLabel
    $state.volume_status = 'created'
    Save-DeploymentState -Config $config -State $state | Out-Null
    Wait-VastVolumeVisible -Config $config -VolumeId $state.volume_id | Out-Null
    Write-Host "Created volume $($state.volume_id)." -ForegroundColor Green
}

$createArguments = @(
    'create', 'instance', [string]$offerId,
    '--image', [string]$config.Vast.Instance.Image,
    '--disk', [string]$config.Vast.Instance.ContainerDiskGb,
    '--label', [string]$config.Vast.Instance.Label,
    '--ssh', '--direct', '--cancel-unavail',
    '--env', (ConvertTo-DockerEnvironmentString -Environment $config.Vast.Instance.Environment),
    '--raw'
)
if ($null -ne $state.volume_id) {
    $createArguments += @(
        '--link-volume', [string]$state.volume_id,
        '--mount-path', [string]$volumeConfig.MountPath
    )
}

try {
    $instanceResponse = Invoke-VastJson -Config $config -Arguments $createArguments
    $state.instance_id = Resolve-CreatedId -Response $instanceResponse
    $state.instance_status = 'created'
    Save-DeploymentState -Config $config -State $state | Out-Null
    Write-Host "Created instance $($state.instance_id)." -ForegroundColor Green
}
catch {
    $state.instance_status = 'create_failed'
    $state.last_error = $_.Exception.Message
    Save-DeploymentState -Config $config -State $state | Out-Null
    throw
}

Wait-VastInstanceRunning -Config $config -InstanceId $state.instance_id | Out-Null
$state.instance_status = 'running'
Save-DeploymentState -Config $config -State $state | Out-Null

$endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
$state.ssh_host = $endpoint.Host
$state.ssh_port = $endpoint.Port
Save-DeploymentState -Config $config -State $state | Out-Null

Write-Host "Instance is ready: ssh $($endpoint.User)@$($endpoint.Host) -p $($endpoint.Port)" -ForegroundColor Green
Write-Host "Next: .\scripts\Provision-Instance.ps1"
