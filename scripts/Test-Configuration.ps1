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
if ([string]$config.Codex.ApprovalPolicy -notin @('untrusted', 'on-request', 'never')) { $errors.Add('Unsupported Codex approval policy.') }
if ([string]$config.Codex.SandboxMode -notin @('read-only', 'workspace-write', 'danger-full-access')) { $errors.Add('Unsupported Codex sandbox mode.') }
if ([string]$config.Codex.AuthMode -notin @('device', 'api-key')) { $errors.Add('Codex.AuthMode must be device or api-key.') }
if ([string]$config.Codex.ApiKeyEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Codex.ApiKeyEnvironmentVariable is invalid.') }
$provisionScriptPath = if ($config.Local.ContainsKey('ProvisionScriptPath')) { [string]$config.Local.ProvisionScriptPath } else { '' }
$codexScriptPath = if ($config.Local.ContainsKey('CodexScriptPath')) { [string]$config.Local.CodexScriptPath } else { '' }
$verifyScriptPath = 'remote/verify-deployment.sh'
if (-not $provisionScriptPath) { $errors.Add('Local.ProvisionScriptPath is required.') }
if (-not $codexScriptPath) { $errors.Add('Local.CodexScriptPath is required.') }
if ($provisionScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $provisionScriptPath) -PathType Leaf)) { $errors.Add("Provision script not found: $provisionScriptPath") }
if ($codexScriptPath -and -not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $codexScriptPath) -PathType Leaf)) { $errors.Add("Codex script not found: $codexScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $verifyScriptPath) -PathType Leaf)) { $errors.Add("Verification script not found: $verifyScriptPath") }
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
