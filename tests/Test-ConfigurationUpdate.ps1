[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$config = Get-DeployConfig -ConfigPath 'config.psd1'
$config.Codex.ProjectRoot = '/workspace/custom-project'
$config.ComfyUI.LocalPort = 39188
$config.WebUI.Repository = 'https://example.invalid/custom-webui.git'
$config.Vast.Ssh.IdentityFile = 'C:\keys\custom-ed25519'
$config.Local.RemoteUploadDirectory = '/tmp/custom-upload'
$originalModelUrl = [string]$config.Anima.Models[0].Url

$updated = Set-DeploymentSearchPreferences `
    -Config $config `
    -Query 'gpu_name in [RTX_5090] gpu_ram>=24 dph_total<=1.25' `
    -SearchLimit 12 `
    -MaxHourlyUsd 1.25 `
    -VolumeEnabled $false `
    -VolumeSizeGb 120 `
    -ApplicationType webui

if ($updated.Vast.Search.Limit -ne 12 -or
    [double]$updated.Vast.Search.MaxHourlyUsd -ne 1.25 -or
    [bool]$updated.Vast.Volume.Enabled -or
    $updated.Vast.Volume.SizeGb -ne 120 -or
    $updated.Application.DefaultType -ne 'webui') {
    throw 'Deployment preference fields were not updated correctly.'
}
if ($updated.Codex.ProjectRoot -ne '/workspace/custom-project' -or
    $updated.ComfyUI.LocalPort -ne 39188 -or
    $updated.WebUI.Repository -ne 'https://example.invalid/custom-webui.git' -or
    $updated.Vast.Ssh.IdentityFile -ne 'C:\keys\custom-ed25519' -or
    $updated.Local.RemoteUploadDirectory -ne '/tmp/custom-upload' -or
    [string]$updated.Anima.Models[0].Url -ne $originalModelUrl) {
    throw 'Updating search preferences reset unrelated deployment configuration.'
}

$template = Get-DeployConfig -ConfigPath 'config.psd1'
$forwardConfig = Get-DeployConfig -ConfigPath 'config.psd1'
$forwardConfig.ComfyUI.Remove('TorchVersion')
$forwardConfig.ComfyUI.Remove('TorchvisionVersion')
$forwardConfig.ComfyUI.Remove('TorchaudioVersion')
$forwardConfig.ComfyUI.Remove('TorchCudaVersion')
$forwardConfig.ComfyUI.Remove('TorchIndexUrl')
$forwardConfig.WebUI.Remove('Localization')
$forwardConfig.WebUI.Remove('Extensions')
$forwardConfig.WebUI.Remove('Commit')
$forwardConfig.WebUI.Remove('TorchVersion')
$forwardConfig.WebUI.Remove('TorchvisionVersion')
$forwardConfig.WebUI.Remove('TorchCudaVersion')
$forwardConfig.WebUI.Remove('TorchIndexUrl')
$forwardConfig.Anima.Remove('WorkflowSha256')
$forwardConfig.Anima.Remove('ManagedWorkflowFileName')
$forwardConfig.Anima.Remove('HiresWorkflowFileName')
$forwardConfig.Anima.Turbo.Remove('Sha256')
$forwardConfig.Anima.Turbo.Strength = 0.9
$forwardConfig.Anima.Remove('ManagedLoRAs')
$forwardConfig.Anima.Remove('ManualLoRASlots')
$forwardConfig.Anima.Hires.Remove('Denoise')
$forwardConfig.Anima.Hires.Scale = 1.6
$forwardConfig.Anima.WorkflowUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_anima_base_v1.json'
$forwardConfig.Codex.ProjectRoot = '/workspace/preserved-forward-config'
$forwardConfig = Add-CurrentFeatureConfigurationDefaults -Config $forwardConfig -Template $template
if ($forwardConfig.ComfyUI.TorchVersion -ne '2.11.0' -or
    $forwardConfig.ComfyUI.TorchvisionVersion -ne '0.26.0' -or
    $forwardConfig.ComfyUI.TorchaudioVersion -ne '2.11.0' -or
    $forwardConfig.ComfyUI.TorchCudaVersion -ne '12.8' -or
    $forwardConfig.ComfyUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128' -or
    $forwardConfig.WebUI.Localization -ne 'zh_CN' -or @($forwardConfig.WebUI.Extensions).Count -ne 2 -or
    $forwardConfig.WebUI.Commit -ne '6e8086edeaef473eb05b48b55518802fadf5bba1' -or
    $forwardConfig.WebUI.TorchVersion -ne '2.11.0' -or
    $forwardConfig.WebUI.TorchvisionVersion -ne '0.26.0' -or
    $forwardConfig.WebUI.TorchCudaVersion -ne '12.8' -or
    $forwardConfig.WebUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128' -or
    [string]$forwardConfig.Anima.WorkflowSha256 -ne [string]$template.Anima.WorkflowSha256 -or
    [string]$forwardConfig.Anima.WorkflowUrl -ne [string]$template.Anima.WorkflowUrl -or
    $forwardConfig.Anima.ManagedWorkflowFileName -ne 'image_anima_base_v1.managed.json' -or
    $forwardConfig.Anima.HiresWorkflowFileName -ne 'image_anima_base_v1.hires.managed.json' -or
    $forwardConfig.Anima.Turbo.Name -ne 'anima-turbo-lora-v0.2.safetensors' -or
    [string]$forwardConfig.Anima.Turbo.Sha256 -ne [string]$template.Anima.Turbo.Sha256 -or
    [double]$forwardConfig.Anima.Turbo.Strength -ne 0.9 -or
    $forwardConfig.Anima.Turbo.EnabledByDefault -or
    @($forwardConfig.Anima.ManagedLoRAs).Count -ne 0 -or
    $forwardConfig.Anima.ManualLoRASlots -ne 2 -or
    [double]$forwardConfig.Anima.Hires.Scale -ne 1.6 -or
    [double]$forwardConfig.Anima.Hires.Denoise -ne 0.35 -or
    $forwardConfig.Codex.ProjectRoot -ne '/workspace/preserved-forward-config') {
    throw 'Forward configuration defaults were not added without resetting custom values.'
}
$customWorkflowConfig = Get-DeployConfig -ConfigPath 'config.psd1'
$customWorkflowConfig.Anima.Remove('WorkflowSha256')
$customWorkflowConfig.Anima.WorkflowUrl = 'https://raw.githubusercontent.com/example/custom/1234567890123456789012345678901234567890/workflow.json'
$customWorkflowConfig = Add-CurrentFeatureConfigurationDefaults -Config $customWorkflowConfig -Template $template
if ($customWorkflowConfig.Anima.WorkflowUrl -notmatch '/example/custom/' -or $customWorkflowConfig.Anima.WorkflowSha256 -ne '') {
    throw 'A custom workflow URL was overwritten or assigned an unrelated template digest.'
}
$customCommit = ('a' * 40) -join ''
$customWorkflowSha = ('b' * 64) -join ''
$forwardConfig.WebUI.Extensions = @(@{ Name = 'custom-managed-extension'; Repository = 'https://example.invalid/custom.git'; Commit = $customCommit; Enabled = $true })
$forwardConfig.ComfyUI.TorchVersion = '8.8.8'
$forwardConfig.ComfyUI.TorchIndexUrl = 'https://example.invalid/custom-comfy-wheels'
$forwardConfig.WebUI.TorchVersion = '9.9.9'
$forwardConfig.WebUI.TorchIndexUrl = 'https://example.invalid/custom-wheels'
$forwardConfig.Anima.WorkflowSha256 = $customWorkflowSha
$forwardConfig.Anima.Turbo.Strength = 0.8
$forwardConfig.Anima.ManagedLoRAs = @(@{
    Name = 'custom-character.safetensors'; Kind = 'character'; Url = 'https://example.invalid/character.safetensors'
    Sha256 = ('c' * 64) -join ''; Strength = 0.7; Enabled = $true
})
$forwardConfig.Anima.Hires.Scale = 1.75
$forwardConfig = Add-CurrentFeatureConfigurationDefaults -Config $forwardConfig -Template $template
if (@($forwardConfig.WebUI.Extensions).Count -ne 1 -or $forwardConfig.WebUI.Extensions[0].Name -ne 'custom-managed-extension' -or
    $forwardConfig.ComfyUI.TorchVersion -ne '8.8.8' -or
    $forwardConfig.ComfyUI.TorchIndexUrl -ne 'https://example.invalid/custom-comfy-wheels' -or
    $forwardConfig.WebUI.TorchVersion -ne '9.9.9' -or
    $forwardConfig.WebUI.TorchIndexUrl -ne 'https://example.invalid/custom-wheels' -or
    $forwardConfig.Anima.WorkflowSha256 -ne $customWorkflowSha -or
    [double]$forwardConfig.Anima.Turbo.Strength -ne 0.8 -or
    @($forwardConfig.Anima.ManagedLoRAs).Count -ne 1 -or
    $forwardConfig.Anima.ManagedLoRAs[0].Name -ne 'custom-character.safetensors' -or
    [double]$forwardConfig.Anima.Hires.Scale -ne 1.75) {
    throw 'Existing workflow or extension feature settings were overwritten by defaults.'
}

$wizardText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Initialize-DeploymentConfig.ps1') -Raw -Encoding UTF8
if (-not $wizardText.Contains("Get-DeployConfig -ConfigPath `$resolvedConfigPath") -or
    $wizardText.Contains('launcher.json')) {
    throw 'The configuration wizard does not update the canonical configuration in place.'
}

$jsonTestDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-json-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $jsonTestDirectory | Out-Null
try {
    $jsonPath = Join-Path $jsonTestDirectory 'remote-config.json'
    Save-JsonFile -Value ([ordered]@{ application = @{ type = 'comfyui' } }) -Path $jsonPath | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($jsonPath)
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Save-JsonFile wrote a UTF-8 BOM that remote Python cannot parse with its default decoder.'
    }
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($decoded.application.type -ne 'comfyui') { throw 'The BOM-free JSON output could not be decoded.' }
} finally {
    Remove-Item -LiteralPath $jsonTestDirectory -Recurse -Force
}

Write-Host 'In-place deployment configuration updates passed.' -ForegroundColor Green
