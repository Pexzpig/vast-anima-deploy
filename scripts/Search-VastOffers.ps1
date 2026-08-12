[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PassThru,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$search = $config.Vast.Search

Write-Host "Vast search scope: $($search.Query)"
Write-Host "Order: $($search.Order); limit: $($search.Limit)"

$response = Invoke-VastJson -Config $config -Arguments @(
    'search', 'offers', [string]$search.Query,
    '--raw', '--limit', [string]$search.Limit,
    '-o', [string]$search.Order
)
$offers = @(ConvertTo-ObjectArray -Value $response -CandidateProperties @('offers'))
if ($offers.Count -eq 0) {
    throw 'No Vast offers matched the stored search scope. Run Start-VastAnima.ps1 -Action Configure to adjust it deliberately.'
}

$record = [ordered]@{
    searched_at = (Get-Date).ToUniversalTime().ToString('o')
    query = [string]$search.Query
    order = [string]$search.Order
    limit = [int]$search.Limit
    offers = $offers
}
$path = Save-JsonFile -Value $record -Path ([string]$search.LastSearchPath)
Write-Host "Saved $($offers.Count) matching offers to $path" -ForegroundColor Green

if (-not $Quiet) {
    @(ConvertTo-VastOfferChoiceRows -Offers $offers) |
        Select-Object -First 10 offer_id, gpu_name, gpu_ram_GB, price_USD_hour, reliability, inet_down_Mbps, machine_id |
        Format-Table -AutoSize | Out-Host
}
if ($PassThru) { $offers | Write-Output }
