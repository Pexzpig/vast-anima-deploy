[CmdletBinding()]
param()

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$provisionScript = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\provision.sh') -Raw -Encoding UTF8
$verifyScript = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\verify-deployment.sh') -Raw -Encoding UTF8
$localProvision = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Provision-Instance.ps1') -Raw -Encoding UTF8
$remoteCli = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-VastRemoteCli.ps1') -Raw -Encoding UTF8

foreach ($expected in @(
    'stage_total=11',
    'Locating and validating the PyTorch base environment',
    'torch.cuda.is_available()',
    'Installing required Ubuntu packages',
    'DEBIAN_FRONTEND=noninteractive',
    'Dpkg::Options::="--force-confdef"',
    'Dpkg::Options::="--force-confold"',
    'pip install --upgrade uv',
    'if [[ "$application_type" == ''comfyui'' ]]',
    '.webui.repository',
    'models/Stable-diffusion',
    'models/text_encoder',
    'models/VAE',
    'start-${service_name}.sh',
    '[download]',
    'verify-deployment.sh',
    'restore supervisor'
) ) {
    if (-not $provisionScript.Contains($expected)) {
        throw "PyTorch application provisioning is missing expected behavior: $expected"
    }
}

foreach ($expected in @('Base PyTorch environment', 'Forge Classic WebUI', 'ComfyUI', 'Supervisor service', 'health endpoint', 'Codex CLI')) {
    if (-not $verifyScript.Contains($expected)) {
        throw "Remote verification is missing a required check: $expected"
    }
}
if (-not $localProvision.Contains('Uploading the remote verification script failed.') -or
    -not $localProvision.Contains('[local 4/5]') -or
    -not $localProvision.Contains('Wait-VastSshReady') -or
    -not $localProvision.Contains('Invoke-NativeCommandCheckedWithRetry') -or
    -not $localProvision.Contains("'LogLevel=QUIET'") -or
    -not $localProvision.Contains("'-T', '-n'") -or
    -not $localProvision.Contains('-Quiet')) {
    throw 'Local provisioning does not upload verification or display staged progress.'
}
if (-not $remoteCli.Contains('tmux new-session -A -s anima') -or
    -not $remoteCli.Contains("'-tt'")) {
    throw 'The remote CLI does not force a TTY and create or attach its tmux session.'
}

Write-Host 'Remote provisioning progress, verification, and CLI recovery checks passed.' -ForegroundColor Green
