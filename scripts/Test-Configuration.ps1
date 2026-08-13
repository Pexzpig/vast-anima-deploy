[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath

$errors = New-Object System.Collections.Generic.List[string]
if (-not [string]$config.Vast.Search.Query) { $errors.Add('Vast.Search.Query is empty.') }
if (-not [string]$config.Vast.Instance.Image) { $errors.Add('Vast.Instance.Image is empty.') }
if ([string]$config.Vast.Instance.Image -notmatch '^vastai/pytorch:[A-Za-z0-9._-]+$') { $errors.Add('Vast.Instance.Image must use a pinned vastai/pytorch tag.') }
if ([string]$config.Vast.Instance.OnStartCommand -ne '/opt/instance-tools/bin/entrypoint.sh') { $errors.Add('The Vast PyTorch entrypoint recovery command is missing.') }
if ([int]$config.Vast.Instance.ContainerDiskGb -lt 30) { $errors.Add('ContainerDiskGb should be at least 30.') }
if ([bool]$config.Vast.Volume.Enabled -and [int]$config.Vast.Volume.SizeGb -lt 50) { $errors.Add('Anima volume should be at least 50 GB.') }
if ([string]$config.Vast.Volume.MountPath -ne '/workspace') { $errors.Add('This example expects the persistent volume at /workspace.') }
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
foreach ($workflowName in @([string]$config.Anima.WorkflowFileName, [string]$config.Anima.ManagedWorkflowFileName)) {
    if ($workflowName -notmatch '^[A-Za-z0-9._-]+\.json$') { $errors.Add("Unsafe Anima workflow filename: $workflowName") }
}
if ([string]$config.Anima.WorkflowFileName -eq [string]$config.Anima.ManagedWorkflowFileName) { $errors.Add('Original and managed workflow filenames must be distinct.') }
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
if (-not $provisionScriptPath) { $errors.Add('Local.ProvisionScriptPath is required.') }
if (-not $codexScriptPath) { $errors.Add('Local.CodexScriptPath is required.') }
if ($provisionScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $provisionScriptPath) -PathType Leaf)) { $errors.Add("Provision script not found: $provisionScriptPath") }
if ($codexScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $codexScriptPath) -PathType Leaf)) { $errors.Add("Codex script not found: $codexScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $verifyScriptPath) -PathType Leaf)) { $errors.Add("Verification script not found: $verifyScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $applicationConfiguratorPath) -PathType Leaf)) { $errors.Add("Application configurator not found: $applicationConfiguratorPath") }
if ([string]$config.Local.RemoteUploadDirectory -notmatch '^/[A-Za-z0-9._/-]+$') { $errors.Add('Local.RemoteUploadDirectory contains unsupported shell characters.') }

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
