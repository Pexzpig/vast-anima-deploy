[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'LoRA-Configuration.psm1') -Force
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath

$errors = New-Object System.Collections.Generic.List[string]
if ([string]$config.Secrets.CivitaiTokenEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Secrets.CivitaiTokenEnvironmentVariable is invalid.') }
if (-not [string]$config.Vast.Search.Query) { $errors.Add('Vast.Search.Query is empty.') }
if (-not [string]$config.Vast.Instance.Image) { $errors.Add('Vast.Instance.Image is empty.') }
if ([string]$config.Vast.Instance.Image -notmatch '^vastai/pytorch:[A-Za-z0-9._-]+$') { $errors.Add('Vast.Instance.Image must use a pinned vastai/pytorch tag.') }
if ([string]$config.Vast.Instance.OnStartCommand -ne '/opt/instance-tools/bin/entrypoint.sh') { $errors.Add('The Vast PyTorch entrypoint recovery command is missing.') }
if ([int]$config.Vast.Instance.ContainerDiskGb -lt 30) { $errors.Add('ContainerDiskGb should be at least 30.') }
if ([bool]$config.Vast.Volume.Enabled -and [int]$config.Vast.Volume.SizeGb -lt 50) { $errors.Add('Anima volume should be at least 50 GB.') }
if ([string]$config.Vast.Volume.MountPath -ne '/workspace') { $errors.Add('This example expects the persistent volume at /workspace.') }
if ([int]$config.Vast.Ssh.ReadyTimeoutSeconds -lt 60 -or [int]$config.Vast.Ssh.ReadyTimeoutSeconds -gt 3600) { $errors.Add('Vast.Ssh.ReadyTimeoutSeconds must be between 60 and 3600.') }
if ([int]$config.Vast.Ssh.ReadyPollIntervalSeconds -lt 1 -or [int]$config.Vast.Ssh.ReadyPollIntervalSeconds -gt 60) { $errors.Add('Vast.Ssh.ReadyPollIntervalSeconds must be between 1 and 60.') }
if ([string]$config.PyTorch.Python -notmatch '^/') { $errors.Add('PyTorch.Python must be an absolute Linux path.') }
if ([string]$config.PyTorch.MinimumCudaVersion -notmatch '^\d+\.\d+$') { $errors.Add('PyTorch.MinimumCudaVersion must use major.minor format.') }
if ([string]$config.Application.DefaultType -notin @('comfyui', 'webui')) { $errors.Add('Application.DefaultType must be comfyui or webui.') }

foreach ($applicationName in @('ComfyUI', 'WebUI')) {
    $application = $config[$applicationName]
    if (-not $application) { $errors.Add("$applicationName configuration is missing."); continue }
    if ([string]$application.ListenHost -notin @('127.0.0.1', 'localhost')) { $errors.Add("$applicationName must listen on localhost for the SSH-only design.") }
    if ([int]$application.Port -lt 1024 -or [int]$application.Port -gt 65535) { $errors.Add("$applicationName remote port is invalid.") }
    if ([int]$application.LocalPort -lt 1024 -or [int]$application.LocalPort -gt 65535) { $errors.Add("$applicationName local tunnel port is invalid.") }
    if ([string]$application.Root -notmatch '^/workspace/') { $errors.Add("$applicationName root must be under /workspace.") }
    if ([string]$application.Venv -notmatch '^/workspace/') { $errors.Add("$applicationName virtual environment must be under /workspace.") }
}
if ([int]$config.ComfyUI.Port -eq [int]$config.WebUI.Port) { $errors.Add('ComfyUI and WebUI remote ports must be distinct.') }
if ([int]$config.ComfyUI.LocalPort -eq [int]$config.WebUI.LocalPort) { $errors.Add('ComfyUI and WebUI local tunnel ports must be distinct.') }
if ([string]$config.ComfyUI.Python -ne (([string]$config.ComfyUI.Venv).TrimEnd('/') + '/bin/python')) {
    $errors.Add('ComfyUI.Python must be the Python executable inside ComfyUI.Venv.')
}
if ([string]$config.ComfyUI.TorchVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [string]$config.ComfyUI.TorchvisionVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [string]$config.ComfyUI.TorchaudioVersion -notmatch '^\d+\.\d+\.\d+$') {
    $errors.Add('ComfyUI Torch, Torchvision, and Torchaudio versions must use major.minor.patch format.')
}
if ([string]$config.ComfyUI.TorchCudaVersion -notmatch '^\d+\.\d+$') {
    $errors.Add('ComfyUI.TorchCudaVersion must use major.minor format.')
}
if ([string]$config.ComfyUI.TorchIndexUrl -notmatch '^https://download\.pytorch\.org/whl/cu\d+$') {
    $errors.Add('ComfyUI.TorchIndexUrl must use the official HTTPS PyTorch CUDA wheel index.')
}
if ([string]$config.ComfyUI.TorchVersion -ne '2.11.0' -or
    [string]$config.ComfyUI.TorchvisionVersion -ne '0.26.0' -or
    [string]$config.ComfyUI.TorchaudioVersion -ne '2.11.0' -or
    [string]$config.ComfyUI.TorchCudaVersion -ne '12.8' -or
    [string]$config.ComfyUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128') {
    $errors.Add('ComfyUI must use the validated Torch 2.11.0 / Torchvision 0.26.0 / Torchaudio 2.11.0 / CUDA 12.8 wheel set.')
}
if ([string]$config.WebUI.Repository -ne 'https://github.com/Haoming02/sd-webui-forge-classic.git' -or [string]$config.WebUI.Ref -ne 'neo') {
    $errors.Add('WebUI must use the Haoming02 Forge Classic neo branch.')
}
if ([string]$config.WebUI.Commit -ne '6e8086edeaef473eb05b48b55518802fadf5bba1') {
    $errors.Add('WebUI.Commit must pin the validated Forge Classic 2.24 commit.')
}
if ([string]$config.WebUI.Python -ne (([string]$config.WebUI.Venv).TrimEnd('/') + '/bin/python')) {
    $errors.Add('WebUI.Python must be the Python executable inside WebUI.Venv.')
}
if ([string]$config.WebUI.TorchVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [string]$config.WebUI.TorchvisionVersion -notmatch '^\d+\.\d+\.\d+$') {
    $errors.Add('WebUI Torch and Torchvision versions must use major.minor.patch format.')
}
if ([string]$config.WebUI.TorchCudaVersion -notmatch '^\d+\.\d+$') {
    $errors.Add('WebUI.TorchCudaVersion must use major.minor format.')
}
if ([string]$config.WebUI.TorchIndexUrl -notmatch '^https://download\.pytorch\.org/whl/cu\d+$') {
    $errors.Add('WebUI.TorchIndexUrl must use the official HTTPS PyTorch CUDA wheel index.')
}
if ([string]$config.WebUI.TorchVersion -ne '2.11.0' -or
    [string]$config.WebUI.TorchvisionVersion -ne '0.26.0' -or
    [string]$config.WebUI.TorchCudaVersion -ne '12.8' -or
    [string]$config.WebUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128') {
    $errors.Add('WebUI must use the validated Torch 2.11.0 / Torchvision 0.26.0 / CUDA 12.8 wheel set.')
}
if (-not $config.WebUI.ContainsKey('Localization') -or [string]$config.WebUI.Localization -ne 'zh_CN') {
    $errors.Add('WebUI.Localization must be zh_CN.')
}
if (-not $config.WebUI.ContainsKey('Extensions')) {
    $errors.Add('WebUI.Extensions is required. Run the configuration wizard once to add current feature defaults.')
} else {
    $extensionNames = New-Object System.Collections.Generic.List[string]
    foreach ($extension in @($config.WebUI.Extensions)) {
        $name = [string]$extension.Name
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { $errors.Add("Unsafe WebUI extension directory name: $name") }
        if ([string]$extension.Repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$') {
            $errors.Add("WebUI extension '$name' must use an HTTPS GitHub .git URL.")
        }
        if ([string]$extension.Commit -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add("WebUI extension '$name' must pin a 40-character commit.") }
        if (-not $extension.ContainsKey('Enabled') -or -not [bool]$extension.Enabled) { $errors.Add("WebUI extension '$name' must be enabled.") }
        if ($extensionNames.Contains($name)) { $errors.Add("Duplicate WebUI extension name: $name") } else { $extensionNames.Add($name) }
    }
    foreach ($requiredExtension in @('tag-autocomplete', 'stable-diffusion-webui-localization-zh_CN')) {
        if (-not $extensionNames.Contains($requiredExtension)) { $errors.Add("Required WebUI extension is missing: $requiredExtension") }
    }
}
$requiredPackages = @('git', 'ffmpeg', 'libgl1', 'libglib2.0-0', 'wget', 'curl', 'aria2', 'tmux', 'jq', 'supervisor')
foreach ($package in $requiredPackages) {
    if ($package -notin @($config.System.Packages)) { $errors.Add("Required Ubuntu package is missing: $package") }
}
if (@($config.Anima.Models).Count -lt 3) { $errors.Add('Anima.Models must include diffusion model, text encoder, and VAE.') }
foreach ($model in @($config.Anima.Models)) {
    if (-not [string]$model.Name -or -not [string]$model.ComfyFolder -or -not [string]$model.WebUiFolder -or -not [string]$model.Url) {
        $errors.Add('Each Anima model requires Name, ComfyFolder, WebUiFolder, and Url.')
    }
}
if (-not $config.Anima.ContainsKey('WorkflowSha256') -or [string]$config.Anima.WorkflowSha256 -notmatch '^[0-9a-fA-F]{64}$') {
    $errors.Add('Anima.WorkflowSha256 must be a 64-character SHA-256 value.')
}
if ([string]$config.Anima.WorkflowUrl -notmatch '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-fA-F]{40}/') {
    $errors.Add('Anima.WorkflowUrl must use raw.githubusercontent.com over HTTPS and pin a 40-character commit.')
}
foreach ($workflowName in @(
    [string]$config.Anima.WorkflowFileName,
    [string]$config.Anima.ManagedWorkflowFileName,
    [string]$config.Anima.HiresWorkflowFileName
)) {
    if ($workflowName -notmatch '^[A-Za-z0-9._-]+\.json$') { $errors.Add("Unsafe Anima workflow filename: $workflowName") }
}
$workflowNames = @(
    [string]$config.Anima.WorkflowFileName,
    [string]$config.Anima.ManagedWorkflowFileName,
    [string]$config.Anima.HiresWorkflowFileName
)
if (@($workflowNames | Select-Object -Unique).Count -ne 3) { $errors.Add('Original, standard, and hires workflow filenames must be distinct.') }
$turbo = $config.Anima.Turbo
if (-not $turbo -or [string]$turbo.Name -ne 'anima-turbo-lora-v0.2.safetensors' -or
    [string]$turbo.Url -ne 'https://huggingface.co/circlestone-labs/Anima-Official-LoRAs/resolve/218b5466a07e8a79328dd8b73ff810706d73cb86/anima-turbo-lora-v0.2.safetensors' -or
    [string]$turbo.Sha256 -ne '1b55e40bdb1d0e5a78cb498f245fccfdaae97823265db957d2aabdcf4cd3caf1') {
    $errors.Add('Anima.Turbo must use the pinned official Turbo LoRA v0.2 file, immutable URL, and SHA-256.')
} else {
    if ([double]$turbo.Strength -lt -2 -or [double]$turbo.Strength -gt 2) { $errors.Add('Anima.Turbo.Strength must be between -2.0 and 2.0.') }
    if ([int]$turbo.Steps -lt 8 -or [int]$turbo.Steps -gt 12) { $errors.Add('Anima.Turbo.Steps must be between 8 and 12.') }
    if ([double]$turbo.Cfg -ne 1.0) { $errors.Add('Anima.Turbo.Cfg must be 1.0.') }
    if (-not $turbo.ContainsKey('EnabledByDefault') -or $turbo.EnabledByDefault -isnot [bool]) { $errors.Add('Anima.Turbo.EnabledByDefault must be a Boolean.') }
}
if ([int]$config.Anima.ManualLoRASlots -ne 2) { $errors.Add('Anima.ManualLoRASlots must provide the character and style slots (2).') }
$managedLoRANames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($lora in @($config.Anima.ManagedLoRAs)) {
    $loraName = [string]$lora.Name
    if ($loraName -notmatch '^[A-Za-z0-9._-]+\.safetensors$') { $errors.Add("Unsafe managed Anima LoRA filename: $loraName") }
    if ([string]$lora.Kind -notin @('character', 'style')) { $errors.Add("Managed Anima LoRA '$loraName' Kind must be character or style.") }
    $downloadUri = $null
    if (-not [Uri]::TryCreate([string]$lora.Url, [UriKind]::Absolute, [ref]$downloadUri) -or $downloadUri.Scheme -ne 'https') {
        $errors.Add("Managed Anima LoRA '$loraName' must use a public HTTPS URL.")
    } elseif ($downloadUri.UserInfo) {
        $errors.Add("Managed Anima LoRA '$loraName' URL must not contain embedded credentials.")
    }
    if ([string]$lora.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { $errors.Add("Managed Anima LoRA '$loraName' must provide a SHA-256 value.") }
    if ([double]$lora.Strength -lt -2 -or [double]$lora.Strength -gt 2) { $errors.Add("Managed Anima LoRA '$loraName' strength must be between -2.0 and 2.0.") }
    if (-not $lora.ContainsKey('Enabled') -or $lora.Enabled -isnot [bool]) { $errors.Add("Managed Anima LoRA '$loraName' Enabled flag must be a Boolean.") }
    if ([string]$lora.Source -notin @('civitai', 'direct')) { $errors.Add("Managed Anima LoRA '$loraName' Source must be civitai or direct.") }
    if (-not $lora.ContainsKey('AutoApplyInComfyUI') -or $lora.AutoApplyInComfyUI -isnot [bool]) { $errors.Add("Managed Anima LoRA '$loraName' AutoApplyInComfyUI must be a Boolean.") }
    if ([string]$lora.BaseModel -notmatch '(?i)\bAnima\b') { $errors.Add("Managed Anima LoRA '$loraName' must declare an Anima base model.") }
    if ($lora.TriggerWords -is [string] -or $lora.TriggerWords -isnot [System.Collections.IEnumerable]) {
        $errors.Add("Managed Anima LoRA '$loraName' TriggerWords must be an array.")
    } else {
        foreach ($triggerWord in @($lora.TriggerWords)) {
            if (-not ($triggerWord -is [string]) -or [string]::IsNullOrWhiteSpace([string]$triggerWord) -or ([string]$triggerWord).Length -gt 200) {
                $errors.Add("Managed Anima LoRA '$loraName' has an invalid trigger word.")
            }
        }
    }
    $sourcePageUri = $null
    if ([string]$lora.SourcePageUrl) {
        if (-not [Uri]::TryCreate([string]$lora.SourcePageUrl, [UriKind]::Absolute, [ref]$sourcePageUri) -or $sourcePageUri.Scheme -ne 'https') {
            $errors.Add("Managed Anima LoRA '$loraName' SourcePageUrl must use HTTPS.")
        } elseif ($sourcePageUri.UserInfo) {
            $errors.Add("Managed Anima LoRA '$loraName' SourcePageUrl must not contain embedded credentials.")
        }
    }
    if ([string]$lora.SourcePageUrl -match '(?i)(?:[?&#]|^)token=') { $errors.Add("Managed Anima LoRA '$loraName' SourcePageUrl must not contain an access token.") }
    if ([string]$lora.Url -match '(?i)(?:[?&#]|^)token=') { $errors.Add("Managed Anima LoRA '$loraName' URL must not contain an access token.") }
    if ([string]$lora.Source -eq 'civitai') {
        if ($null -eq $downloadUri -or $downloadUri.Host -notin @('civitai.com', 'www.civitai.com')) { $errors.Add("Managed Civitai LoRA '$loraName' must use a civitai.com download URL.") }
        if ($null -eq $sourcePageUri -or $sourcePageUri.Host -notin @('civitai.com', 'www.civitai.com')) { $errors.Add("Managed Civitai LoRA '$loraName' must use a civitai.com source page URL.") }
        if ([int64]$lora.ModelVersionId -le 0) { $errors.Add("Managed Civitai LoRA '$loraName' requires a fixed ModelVersionId.") }
        if ($null -ne $lora.ModelId -and [int64]$lora.ModelId -le 0) { $errors.Add("Managed Civitai LoRA '$loraName' has an invalid ModelId.") }
        if ($lora.ContainsKey('FileId') -and $null -ne $lora.FileId -and [int64]$lora.FileId -le 0) { $errors.Add("Managed Civitai LoRA '$loraName' has an invalid FileId.") }
    }
    if (-not $lora.ContainsKey('OriginalFileName') -or [string]::IsNullOrWhiteSpace([string]$lora.OriginalFileName) -or
        ([string]$lora.OriginalFileName).Length -gt 255 -or
        @(([string]$lora.OriginalFileName).ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
        $errors.Add("Managed Anima LoRA '$loraName' has an invalid OriginalFileName.")
    }
    if (-not $managedLoRANames.Add($loraName) -or $loraName -eq [string]$turbo.Name) { $errors.Add("Duplicate managed Anima LoRA filename: $loraName") }
}
$hires = $config.Anima.Hires
if (-not $hires) {
    $errors.Add('Anima.Hires configuration is required.')
} else {
    if ([double]$hires.Scale -lt 1.0 -or [double]$hires.Scale -gt 2.0) { $errors.Add('Anima.Hires.Scale must be between 1.0 and 2.0.') }
    if ([string]$hires.UpscaleMethod -notin @('nearest-exact', 'bilinear', 'area', 'bicubic', 'bislerp')) { $errors.Add('Anima.Hires.UpscaleMethod is unsupported by the pinned ComfyUI release.') }
    if ([int]$hires.Steps -lt 1 -or [int]$hires.Steps -gt 200) { $errors.Add('Anima.Hires.Steps must be 1-200.') }
    if ([double]$hires.Cfg -le 0 -or [double]$hires.Cfg -gt 30) { $errors.Add('Anima.Hires.Cfg must be greater than 0 and at most 30.') }
    if ([double]$hires.Denoise -le 0 -or [double]$hires.Denoise -gt 1) { $errors.Add('Anima.Hires.Denoise must be greater than 0 and at most 1.') }
    if ([string]$hires.Sampler -notmatch '^[A-Za-z0-9_+-]+$') { $errors.Add('Anima.Hires.Sampler contains unsupported characters.') }
    if ([string]$hires.Scheduler -notmatch '^[A-Za-z0-9_+-]+$') { $errors.Add('Anima.Hires.Scheduler contains unsupported characters.') }
}
$baseline = $config.Anima.Baseline
if ([int]$baseline.Width -lt 256 -or [int]$baseline.Width -gt 4096 -or [int]$baseline.Width % 16 -ne 0) { $errors.Add('Anima.Baseline.Width must be 256-4096 and divisible by 16.') }
if ([int]$baseline.Height -lt 256 -or [int]$baseline.Height -gt 4096 -or [int]$baseline.Height % 16 -ne 0) { $errors.Add('Anima.Baseline.Height must be 256-4096 and divisible by 16.') }
if ([int]$baseline.Steps -lt 1 -or [int]$baseline.Steps -gt 200) { $errors.Add('Anima.Baseline.Steps must be 1-200.') }
if ([double]$baseline.Cfg -le 0 -or [double]$baseline.Cfg -gt 30) { $errors.Add('Anima.Baseline.Cfg must be greater than 0 and at most 30.') }
if ([string]$baseline.Sampler -notmatch '^[A-Za-z0-9_+-]+$') { $errors.Add('Anima.Baseline.Sampler contains unsupported characters.') }
if ([string]$baseline.Scheduler -notmatch '^[A-Za-z0-9_+-]+$') { $errors.Add('Anima.Baseline.Scheduler contains unsupported characters.') }
if ([string]$config.Codex.ApprovalPolicy -notin @('untrusted', 'on-request', 'never')) { $errors.Add('Unsupported Codex approval policy.') }
if ([string]$config.Codex.SandboxMode -notin @('read-only', 'workspace-write', 'danger-full-access')) { $errors.Add('Unsupported Codex sandbox mode.') }
if ([string]$config.Codex.AuthMode -notin @('device', 'api-key')) { $errors.Add('Codex.AuthMode must be device or api-key.') }
if ([string]$config.Codex.ApiKeyEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Codex.ApiKeyEnvironmentVariable is invalid.') }
$provisionScriptPath = if ($config.Local.ContainsKey('ProvisionScriptPath')) { [string]$config.Local.ProvisionScriptPath } else { '' }
$codexScriptPath = if ($config.Local.ContainsKey('CodexScriptPath')) { [string]$config.Local.CodexScriptPath } else { '' }
$verifyScriptPath = 'remote/verify-deployment.sh'
$applicationConfiguratorPath = 'remote/configure-application.py'
$localLoRADirectory = if ($config.Local.ContainsKey('LoRADirectory')) { [string]$config.Local.LoRADirectory } else { '' }
if (-not $provisionScriptPath) { $errors.Add('Local.ProvisionScriptPath is required.') }
if (-not $codexScriptPath) { $errors.Add('Local.CodexScriptPath is required.') }
if ($provisionScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $provisionScriptPath) -PathType Leaf)) { $errors.Add("Provision script not found: $provisionScriptPath") }
if ($codexScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $codexScriptPath) -PathType Leaf)) { $errors.Add("Codex script not found: $codexScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $verifyScriptPath) -PathType Leaf)) { $errors.Add("Verification script not found: $verifyScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $applicationConfiguratorPath) -PathType Leaf)) { $errors.Add("Application configurator not found: $applicationConfiguratorPath") }
if ([string]$config.Local.RemoteUploadDirectory -notmatch '^/[A-Za-z0-9._/-]+$') { $errors.Add('Local.RemoteUploadDirectory contains unsupported shell characters.') }
if (-not $localLoRADirectory) {
    $errors.Add('Local.LoRADirectory is required.')
} else {
    try { Resolve-LocalLoRADirectory -ProjectRoot $script:ProjectRoot -RelativePath $localLoRADirectory | Out-Null }
    catch { $errors.Add("Local.LoRADirectory is invalid: $($_.Exception.Message)") }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    throw "Configuration validation failed with $($errors.Count) error(s)."
}

Write-Host 'Configuration is valid.' -ForegroundColor Green
Write-Host "Stored GPU search scope: $($config.Vast.Search.Query)"
Write-Host "Container image: $($config.Vast.Instance.Image)"
Write-Host "Default application: $($config.Application.DefaultType)"
Write-Host "Instance disk: $($config.Vast.Instance.ContainerDiskGb) GB"
Write-Host "Persistent volume option: $(if ([bool]$config.Vast.Volume.Enabled) { "$($config.Vast.Volume.SizeGb) GB at $($config.Vast.Volume.MountPath)" } else { 'disabled' })"
Write-Host "ComfyUI: $($config.ComfyUI.ListenHost):$($config.ComfyUI.Port) -> localhost:$($config.ComfyUI.LocalPort)"
Write-Host "Forge WebUI: $($config.WebUI.ListenHost):$($config.WebUI.Port) -> localhost:$($config.WebUI.LocalPort)"
Write-Host "Codex: $($config.Codex.SandboxMode), approvals $($config.Codex.ApprovalPolicy), auth $($config.Codex.AuthMode)"
