[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$requiredModels = @(
    'RTX_4090', 'RTX_5090',
    'RTX_2000Ada', 'RTX_5000Ada', 'RTX_6000Ada', 'RTX_PRO_6000_WS',
    'RTX_A2000', 'RTX_A5000', 'RTX_A6000',
    'A10', 'A40', 'L4', 'L40S', 'A100_PCIE', 'A100_SXM4', 'A800_PCIE',
    'H100_PCIE', 'H100_SXM', 'H100_NVL', 'H200', 'H200_NVL', 'B200'
)

$wizardText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Initialize-SearchProfile.ps1') -Raw -Encoding UTF8
foreach ($model in $requiredModels) {
    if ($wizardText -notmatch ("'{0}'" -f [regex]::Escape($model))) {
        throw "GPU catalog is missing $model."
    }
}

foreach ($configPath in @('config.psd1', 'profiles/vast-comfy/config.psd1')) {
    $config = Get-DeployConfig -ConfigPath $configPath
    $query = [string]$config.Vast.Search.Query
    if ($query -notmatch 'gpu_name in \[(?<models>[^\]]+)\]') {
        throw "GPU list was not found in $configPath."
    }
    $models = @($Matches.models -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($models.Count -lt 35) {
        throw "$configPath only contains $($models.Count) default GPU models."
    }
    if (@($models | Select-Object -Unique).Count -ne $models.Count) {
        throw "$configPath contains duplicate GPU models."
    }
    foreach ($model in ($requiredModels | Where-Object { $_ -ne 'RTX_2000Ada' -and $_ -ne 'RTX_A2000' })) {
        if ($models -notcontains $model) { throw "$configPath default query is missing $model." }
    }
}

Write-Host 'Expanded RTX Ada, RTX A, and data-center GPU catalog passed.' -ForegroundColor Green
