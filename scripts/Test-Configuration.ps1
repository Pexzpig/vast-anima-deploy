[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath

$errors = New-Object System.Collections.Generic.List[string]
$installationMode = if ($config.ComfyUI.ContainsKey('InstallationMode')) { [string]$config.ComfyUI.InstallationMode } else { 'managed' }
if (-not [string]$config.Vast.Search.Query) { $errors.Add('Vast.Search.Query is empty.') }
if (-not [string]$config.Vast.Instance.Image) { $errors.Add('Vast.Instance.Image is empty.') }
if ([int]$config.Vast.Instance.ContainerDiskGb -lt 20) { $errors.Add('ContainerDiskGb should be at least 20.') }
if ([bool]$config.Vast.Volume.Enabled -and [int]$config.Vast.Volume.SizeGb -lt 50) { $errors.Add('Anima volume should be at least 50 GB.') }
if ([string]$config.Vast.Volume.MountPath -ne '/workspace') { $errors.Add('This example expects the persistent volume at /workspace.') }
if ($installationMode -notin @('managed', 'preinstalled')) { $errors.Add('ComfyUI.InstallationMode must be managed or preinstalled.') }
if ($installationMode -eq 'preinstalled' -and [string]$config.Vast.Instance.Image -notmatch '^vastai/comfy:') {
    $errors.Add('Preinstalled mode expects a pinned vastai/comfy image tag.')
}
if ($installationMode -eq 'preinstalled' -and [string]$config.Vast.Instance.Image -notmatch (':' + [regex]::Escape([string]$config.ComfyUI.Ref) + '-')) {
    $errors.Add('The vastai/comfy image tag and ComfyUI.Ref must identify the same ComfyUI release.')
}
if ([string]$config.ComfyUI.ListenHost -notin @('127.0.0.1', 'localhost')) { $errors.Add('ComfyUI must listen on localhost for the SSH-only design.') }
if ([int]$config.ComfyUI.Port -lt 1024 -or [int]$config.ComfyUI.Port -gt 65535) { $errors.Add('ComfyUI port is invalid.') }
if (@($config.Anima.Models).Count -lt 3) { $errors.Add('Anima.Models must include diffusion model, text encoder, and VAE.') }
if ([string]$config.Codex.ApprovalPolicy -notin @('untrusted', 'on-request', 'never')) { $errors.Add('Unsupported Codex approval policy.') }
if ([string]$config.Codex.SandboxMode -notin @('read-only', 'workspace-write', 'danger-full-access')) { $errors.Add('Unsupported Codex sandbox mode.') }
if ([string]$config.Codex.AuthMode -notin @('device', 'api-key')) { $errors.Add('Codex.AuthMode must be device or api-key.') }
if ([string]$config.Codex.ApiKeyEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Codex.ApiKeyEnvironmentVariable is invalid.') }
$provisionScriptPath = if ($config.Local.ContainsKey('ProvisionScriptPath')) { [string]$config.Local.ProvisionScriptPath } else { 'remote/provision.sh' }
$codexScriptPath = if ($config.Local.ContainsKey('CodexScriptPath')) { [string]$config.Local.CodexScriptPath } else { 'remote/configure-codex.sh' }
$verifyScriptPath = 'remote/verify-deployment.sh'
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $provisionScriptPath) -PathType Leaf)) { $errors.Add("Provision script not found: $provisionScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $codexScriptPath) -PathType Leaf)) { $errors.Add("Codex script not found: $codexScriptPath") }
if (-not (Test-Path -LiteralPath (Resolve-ProjectPath -Path $verifyScriptPath) -PathType Leaf)) { $errors.Add("Verification script not found: $verifyScriptPath") }
if ([string]$config.Local.RemoteUploadDirectory -notmatch '^/[A-Za-z0-9._/-]+$') { $errors.Add('Local.RemoteUploadDirectory contains unsupported shell characters.') }

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    throw "Configuration validation failed with $($errors.Count) error(s)."
}

Write-Host 'Configuration is valid.' -ForegroundColor Green
Write-Host "Stored GPU search scope: $($config.Vast.Search.Query)"
Write-Host "Container image: $($config.Vast.Instance.Image)"
Write-Host "ComfyUI installation mode: $installationMode"
Write-Host "Instance disk: $($config.Vast.Instance.ContainerDiskGb) GB"
Write-Host "Persistent volume option: $(if ([bool]$config.Vast.Volume.Enabled) { "$($config.Vast.Volume.SizeGb) GB at $($config.Vast.Volume.MountPath)" } else { 'disabled' })"
Write-Host "ComfyUI: $($config.ComfyUI.ListenHost):$($config.ComfyUI.Port)"
Write-Host "Codex: $($config.Codex.SandboxMode), approvals $($config.Codex.ApprovalPolicy), auth $($config.Codex.AuthMode)"
