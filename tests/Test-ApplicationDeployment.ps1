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
if ([string]$config.ComfyUI.TorchVersion -ne '2.11.0' -or
    [string]$config.ComfyUI.TorchvisionVersion -ne '0.26.0' -or
    [string]$config.ComfyUI.TorchaudioVersion -ne '2.11.0' -or
    [string]$config.ComfyUI.TorchCudaVersion -ne '12.8' -or
    [string]$config.ComfyUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128') {
    throw 'ComfyUI CUDA/PyTorch dependencies are not pinned.'
}
if ([string]$config.WebUI.Repository -ne 'https://github.com/Haoming02/sd-webui-forge-classic.git' -or
    [string]$config.WebUI.Ref -ne 'neo') {
    throw 'Forge Classic WebUI repository or branch is incorrect.'
}
if ([string]$config.WebUI.Commit -ne '6e8086edeaef473eb05b48b55518802fadf5bba1' -or
    [string]$config.WebUI.TorchVersion -ne '2.11.0' -or
    [string]$config.WebUI.TorchvisionVersion -ne '0.26.0' -or
    [string]$config.WebUI.TorchCudaVersion -ne '12.8' -or
    [string]$config.WebUI.TorchIndexUrl -ne 'https://download.pytorch.org/whl/cu128') {
    throw 'Forge Classic WebUI application or CUDA/PyTorch dependencies are not pinned.'
}
if ([string]$config.Anima.WorkflowSha256 -ne 'f5d093bfb97409b5e3798394044baa8e775235335ffb881f0de0bf09a470cfe2' -or
    [string]$config.Anima.WorkflowUrl -notmatch '12199d938df3c531853036116c145286790a7be7' -or
    [string]$config.Anima.ManagedWorkflowFileName -ne 'image_anima_base_v1.managed.json' -or
    [string]$config.Anima.HiresWorkflowFileName -ne 'image_anima_base_v1.hires.managed.json') {
    throw 'The pinned or managed Anima workflow configuration is incorrect.'
}
if ([string]$config.Anima.Turbo.Name -ne 'anima-turbo-lora-v0.2.safetensors' -or
    [string]$config.Anima.Turbo.Url -notmatch '218b5466a07e8a79328dd8b73ff810706d73cb86' -or
    [string]$config.Anima.Turbo.Sha256 -ne '1b55e40bdb1d0e5a78cb498f245fccfdaae97823265db957d2aabdcf4cd3caf1' -or
    [double]$config.Anima.Turbo.Strength -ne 1.0 -or [int]$config.Anima.Turbo.Steps -ne 8 -or
    [double]$config.Anima.Turbo.Cfg -ne 1.0 -or [bool]$config.Anima.Turbo.EnabledByDefault -or
    [int]$config.Anima.ManualLoRASlots -ne 2 -or @($config.Anima.ManagedLoRAs).Count -ne 0) {
    throw 'The pinned optional Anima Turbo or LoRA slot configuration is incorrect.'
}
if ([double]$config.Anima.Hires.Scale -ne 1.5 -or $config.Anima.Hires.UpscaleMethod -ne 'bislerp' -or
    [int]$config.Anima.Hires.Steps -ne 20 -or [double]$config.Anima.Hires.Cfg -ne 4.5 -or
    $config.Anima.Hires.Sampler -ne 'er_sde' -or $config.Anima.Hires.Scheduler -ne 'simple' -or
    [double]$config.Anima.Hires.Denoise -ne 0.35) {
    throw 'The managed Anima hires defaults are incorrect.'
}
$extensionCommits = @{}
foreach ($extension in @($config.WebUI.Extensions)) { $extensionCommits[[string]$extension.Name] = [string]$extension.Commit }
if ($config.WebUI.Localization -ne 'zh_CN' -or
    $extensionCommits['tag-autocomplete'] -ne '8766965a305b09aee4aa65aa754f84feaf801437' -or
    $extensionCommits['stable-diffusion-webui-localization-zh_CN'] -ne '3b310d9c72c78264ab37d7651ab2638945e28dd8') {
    throw 'Pinned WebUI extensions or localization are incorrect.'
}

$entryText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-VastAnima.ps1') -Raw -Encoding UTF8
if ($entryText.Contains('launcher.json') -or $entryText.Contains('profile')) {
    throw 'The main entry point still reads an obsolete selection layer.'
}
foreach ($expected in @(
    "'9' = 'Test'",
    "'10' = 'Destroy'",
    "'11' = 'RemoveVolume'",
    "'12' = 'ConnectExisting'",
    'user-config\deployment.json'
)) {
    if (-not $entryText.Contains($expected)) {
        throw "The single-deployment entry point is missing expected behavior: $expected"
    }
}
foreach ($expected in @(
    'Sync-StartupAccountInstances',
    'Get-VastAccountInstances -Config $Config -TimeoutSeconds 30',
    'Sync-DeploymentInstanceState -Config $Config -State $state -AccountInstances $instances',
    '$startupAccountInstances = @(Sync-StartupAccountInstances -Config $config)'
)) {
    if (-not $entryText.Contains($expected)) {
        throw "The main entry point is missing startup account reconciliation: $expected"
    }
}
if ([regex]::Matches($entryText, '\$startupAccountInstances\s*=\s*@\(Sync-StartupAccountInstances').Count -ne 1) {
    throw 'Startup account reconciliation is not invoked exactly once per entry-script run.'
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
