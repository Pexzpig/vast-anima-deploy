[CmdletBinding()]
param()

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$provisionScript = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\provision.sh') -Raw -Encoding UTF8
$verifyScript = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\verify-deployment.sh') -Raw -Encoding UTF8
$localProvision = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Provision-Instance.ps1') -Raw -Encoding UTF8
$remoteCli = Get-Content -LiteralPath (Join-Path $projectRoot 'Open-VastRemoteCli.ps1') -Raw -Encoding UTF8
$applicationConfigurator = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\configure-application.py') -Raw -Encoding UTF8
$localLoRAInstaller = Get-Content -LiteralPath (Join-Path $projectRoot 'remote\install-local-loras.py') -Raw -Encoding UTF8

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
    '.comfyui.torch_index_url',
    'Rebuilding incompatible managed ComfyUI environment',
    'comfyui-requirements-managed.txt',
    'comfyui-pytorch-constraints.txt',
    'Pinned ComfyUI PyTorch environment failed validation after installing application requirements.',
    '.anima.turbo.url',
    '.anima.managed_loras[]',
    '.Source',
    'models/Lora',
    '.civitai-curl.conf',
    'Authorization: Bearer',
    'trap cleanup_secrets EXIT',
    'hires_workflow_managed',
    '.webui.repository',
    'models/Stable-diffusion',
    'models/text_encoder',
    'models/VAE',
    'checkout_managed_repository',
    'checkout_pinned_repository',
    '.webui.commit',
    '.webui.torch_index_url',
    'TORCH_COMMAND',
    'Rebuilding incompatible managed WebUI environment',
    'Pinned WebUI PyTorch environment failed validation.',
    "supervisor_state",
    '.webui.extensions[]',
    'prepare-webui',
    'configure-webui',
    'Deferring managed WebUI settings until Forge creates its versioned config.json.',
    "wait_for_application_health ' after managed configuration'",
    'configure-workflow',
    'workflow_sha256',
    '.pre-pinned.',
    'vast-anima-deploy-manifest.json',
    "created_by 'vast-anima-deploy'",
    'start-${service_name}.sh',
    '[download]',
    'verify-deployment.sh',
    'install-local-loras.py',
    'restore supervisor'
) ) {
    if (-not $provisionScript.Contains($expected)) {
        throw "PyTorch application provisioning is missing expected behavior: $expected"
    }
}

foreach ($expected in @('Base PyTorch environment', 'Forge Classic WebUI', 'ComfyUI', 'standard and hires workflows', 'Anima Turbo LoRA', 'Managed Anima LoRA', 'Project-local LoRA', 'WebUI localization', 'VERSION_UID', 'WebUI extension', 'Supervisor service', 'health endpoint', 'Codex CLI')) {
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
    -not $localProvision.Contains('configure-application.py') -or
    -not $localProvision.Contains('workflow_sha256') -or
    -not $localProvision.Contains('hires_workflow_file_name = [string]$config.Anima.HiresWorkflowFileName') -or
    -not $localProvision.Contains('managed_loras = @($config.Anima.ManagedLoRAs)') -or
    -not $localProvision.Contains('local_loras = @($localLoRAs | ForEach-Object') -or
    -not $localProvision.Contains('Get-LocalLoRAFiles') -or
    -not $localProvision.Contains('Uploading local LoRA') -or
    -not $localProvision.Contains('-TimeoutSeconds 0 -Quiet') -or
    -not $localProvision.Contains('CivitaiTokenEnvironmentVariable') -or
    -not $localProvision.Contains('Get-CivitaiCredential') -or
    -not $localProvision.Contains('Test-CivitaiDownloadAccess') -or
    -not $localProvision.Contains('Civitai download preflight failed before remote provisioning') -or
    -not $localProvision.Contains('Using Civitai API Key from') -or
    -not $localProvision.Contains('New-RestrictedSecretFile') -or
    -not $localProvision.Contains('Set-RestrictedCredentialAcl -Path $path') -or
    $localProvision.Contains('Set-Acl -LiteralPath $path -AclObject $security') -or
    $localProvision.Contains('[System.IO.File]::SetAccessControl') -or
    -not $localProvision.Contains('.civitai-token.upload') -or
    -not $localProvision.Contains('Remove-Item -LiteralPath $localCivitaiSecret') -or
    -not $localProvision.Contains('enabled_by_default = [bool]$config.Anima.Turbo.EnabledByDefault') -or
    -not $localProvision.Contains('torchaudio_version = [string]$config.ComfyUI.TorchaudioVersion') -or
    -not $localProvision.Contains('torch_index_url = [string]$config.ComfyUI.TorchIndexUrl') -or
    -not $localProvision.Contains('commit = [string]$config.WebUI.Commit') -or
    -not $localProvision.Contains('torch_version = [string]$config.WebUI.TorchVersion') -or
    -not $localProvision.Contains('torchvision_version = [string]$config.WebUI.TorchvisionVersion') -or
    -not $localProvision.Contains('torch_cuda_version = [string]$config.WebUI.TorchCudaVersion') -or
    -not $localProvision.Contains('torch_index_url = [string]$config.WebUI.TorchIndexUrl') -or
    -not $localProvision.Contains('extensions = @($config.WebUI.Extensions)') -or
    -not $localProvision.Contains('-Quiet')) {
    throw 'Local provisioning does not upload verification or display staged progress.'
}
foreach ($expected in @('verify-stage', 'os.replace', 'shutil.copyfile', 'relative_path', 'staging_id', 'Local LoRA')) {
    if (-not $localLoRAInstaller.Contains($expected)) {
        throw "The local LoRA installer is missing expected behavior: $expected"
    }
}
if ($localProvision.Contains('?token=') -or $provisionScript.Contains('?token=') -or
    -not $provisionScript.Contains('save a Civitai API Key from the ManageLoRA menu')) {
    throw 'A Civitai token is being placed in a persisted or logged URL.'
}
foreach ($expected in @('build_standard_workflow', 'build_hires_workflow', 'configure_model_chain', 'LoraLoaderModelOnly', 'LatentUpscaleBy', 'Base hires refinement (Turbo excluded)', 'ResolutionSelector', 'prepare-webui', 'configure-webui', 'disabled_extensions', 'disable_all_extensions', 'verify-workflow')) {
    if (-not $applicationConfigurator.Contains($expected)) {
        throw "Remote application configurator is missing expected behavior: $expected"
    }
}
if (-not $remoteCli.Contains('tmux new-session -A -s anima') -or
    -not $remoteCli.Contains("'-tt'")) {
    throw 'The remote CLI does not force a TTY and create or attach its tmux session.'
}

Write-Host 'Remote provisioning progress, verification, and CLI recovery checks passed.' -ForegroundColor Green
