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

$launcherText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-VastAnima.ps1') -Raw -Encoding UTF8
if ($launcherText.Contains('SwitchProfile') -or $launcherText.Contains("'base-image'")) {
    throw 'The launcher still exposes obsolete profile/base-image selection.'
}
foreach ($expected in @(
    "'9' = 'Test'",
    "'10' = 'Destroy'",
    "'11' = 'RemoveVolume'",
    'application_type',
    'deployment_image'
)) {
    if (-not $launcherText.Contains($expected)) {
        throw "The single-deployment launcher is missing expected behavior: $expected"
    }
}

$tunnelText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Open-AppTunnel.ps1') -Raw -Encoding UTF8
foreach ($expected in @('Get-DeploymentApplication', '$application.LocalPort', '$application.RemotePort')) {
    if (-not $tunnelText.Contains($expected)) { throw "Dynamic application tunnel is missing: $expected" }
}

Write-Host 'Single PyTorch deployment and selectable application checks passed.' -ForegroundColor Green
