[CmdletBinding()]
param()

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$preinstalledProvision = Get-Content -LiteralPath (Join-Path $projectRoot 'profiles\vast-comfy\remote\provision.sh') -Raw -Encoding UTF8
$managedProvision = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\provision.sh') -Raw -Encoding UTF8
$verifyScript = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\verify-deployment.sh') -Raw -Encoding UTF8
$localProvision = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Provision-Instance.ps1') -Raw -Encoding UTF8
$remoteCli = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-VastRemoteCli.ps1') -Raw -Encoding UTF8

$preinstalledExpectations = @(
    "stage_total=9",
    "git clone --progress --branch `"`$comfy_ref`" --single-branch",
    "The persistent volume hides the image's original /workspace checkout.",
    '[download]',
    'verify-deployment.sh'
)
foreach ($expected in $preinstalledExpectations) {
    if (-not $preinstalledProvision.Contains($expected)) {
        throw "Preinstalled provisioning is missing expected behavior: $expected"
    }
}
if ($preinstalledProvision -match 'Use a fresh profile volume') {
    throw 'Preinstalled provisioning still rejects an empty volume instead of populating it.'
}

foreach ($expected in @('ComfyUI checkout', 'CUDA Python runtime', 'Supervisor service', 'ComfyUI health endpoint', 'Codex CLI')) {
    if (-not $verifyScript.Contains($expected)) {
        throw "Remote verification is missing a required check: $expected"
    }
}
if (-not $managedProvision.Contains('verify-deployment.sh')) {
    throw 'Managed-image provisioning does not run the common remote verification.'
}
if (-not $localProvision.Contains('Uploading the remote verification script failed.') -or
    -not $localProvision.Contains('[local 4/5]')) {
    throw 'Local provisioning does not upload verification or display staged progress.'
}
if (-not $remoteCli.Contains('tmux new-session -A -s anima') -or
    -not $remoteCli.Contains("'-tt'")) {
    throw 'The remote CLI does not force a TTY and create or attach its tmux session.'
}

Write-Host 'Remote provisioning progress, verification, and CLI recovery checks passed.' -ForegroundColor Green
