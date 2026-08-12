[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$config = Get-DeployConfig -ConfigPath 'config.psd1'
if ([string]$config.Vast.Instance.Image -ne 'vastai/pytorch:cuda-12.8.1-auto') {
    throw "Unexpected deployment image: $($config.Vast.Instance.Image)"
}

$comfy = Get-DeploymentApplication -Config $config -State ([pscustomobject]@{ application_type = 'comfyui' })
$webui = Get-DeploymentApplication -Config $config -State ([pscustomobject]@{ application_type = 'webui' })
if ($comfy.ServiceName -ne 'comfyui' -or $comfy.RemotePort -ne 18188 -or $comfy.LocalPort -ne 28188) {
    throw 'ComfyUI application resolution returned unexpected service or ports.'
}
if ($webui.ServiceName -ne 'webui' -or $webui.RemotePort -ne 17860 -or $webui.LocalPort -ne 27860) {
    throw 'WebUI application resolution returned unexpected service or ports.'
}
if ([string]$config.WebUI.Repository -ne 'https://github.com/Haoming02/sd-webui-forge-classic.git' -or
    [string]$config.WebUI.Ref -ne 'neo') {
    throw 'Forge Classic WebUI repository or branch is incorrect.'
}

$entryText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-VastAnima.ps1') -Raw -Encoding UTF8
if ($entryText.Contains('launcher.json') -or $entryText.Contains('profile')) {
    throw 'The main entry point still reads an obsolete selection layer.'
}
foreach ($expected in @(
    "'9' = 'Test'",
    "'10' = 'Destroy'",
    "'11' = 'RemoveVolume'",
    'user-config\deployment.json'
)) {
    if (-not $entryText.Contains($expected)) {
        throw "The single-deployment entry point is missing expected behavior: $expected"
    }
}

$remoteCliText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Open-VastRemoteCli.ps1') -Raw -Encoding UTF8
if (-not $remoteCliText.Contains('user-config/deployment.json') -or
    $remoteCliText.Contains('launcher.json') -or
    $remoteCliText.Contains("@('deployment', 'profile')")) {
    throw 'The remote CLI does not resolve the canonical deployment configuration directly.'
}
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Open-ComfyUITunnel.ps1')) {
    throw 'The obsolete ComfyUI-only tunnel entry point still exists.'
}

$tunnelText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Open-AppTunnel.ps1') -Raw -Encoding UTF8
foreach ($expected in @('Get-DeploymentApplication', '$application.LocalPort', '$application.RemotePort')) {
    if (-not $tunnelText.Contains($expected)) { throw "Dynamic application tunnel is missing: $expected" }
}

Write-Host 'Single PyTorch deployment and selectable application checks passed.' -ForegroundColor Green
