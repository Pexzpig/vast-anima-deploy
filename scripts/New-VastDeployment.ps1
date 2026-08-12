[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath

$existingStatePath = Resolve-ProjectPath -Path ([string]$config.Local.StatePath)
if (Test-Path -LiteralPath $existingStatePath) {
    $existingState = Get-Content -LiteralPath $existingStatePath -Raw | ConvertFrom-Json
    if (Test-DeploymentStateHasActiveResources -State $existingState) {
        throw "An active instance or retained volume is already tracked in $existingStatePath. Destroy/delete it first so paid resources are not orphaned."
    }
    Write-Warning "Replacing a previous deployment record that has no active remote resources: $existingStatePath"
}

# This is intentionally called on every deployment so the saved scope is
# always re-evaluated against current marketplace offers.
$offers = @(& (Join-Path $PSScriptRoot 'Search-VastOffers.ps1') -ConfigPath $ConfigPath -PassThru)
if ($offers.Count -eq 0) { throw 'Search returned no offers.' }

$selectedOffer = $null
$selectedVolumeOffer = $null
$volumeConfig = $config.Vast.Volume

foreach ($offer in $offers) {
    $hourly = [double](Get-ObjectProperty -Object $offer -Names @('dph_total', 'dph') -Default 999999)
    if ($hourly -gt [double]$config.Vast.Search.MaxHourlyUsd) { continue }

    if (-not [bool]$volumeConfig.Enabled) {
        $selectedOffer = $offer
        break
    }

    $machineId = [string](Get-ObjectProperty -Object $offer -Names @('machine_id'))
    if (-not $machineId) { continue }
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
        Write-Warning "Volume search failed for machine $machineId; trying the next GPU offer. $($_.Exception.Message)"
    }
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
if ($selectedVolumeOffer) {
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
Save-DeploymentState -Config $config -State $state | Out-Null

if ([bool]$volumeConfig.Enabled) {
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
