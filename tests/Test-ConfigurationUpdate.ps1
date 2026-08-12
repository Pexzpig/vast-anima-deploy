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
