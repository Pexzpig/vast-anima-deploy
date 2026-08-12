[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
$application = Get-DeploymentApplication -Config $config -State $state
$deploymentImage = [string](Get-ObjectProperty -Object $state -Names @('deployment_image') -Default $config.Vast.Instance.Image)
if ($deploymentImage -ne [string]$config.Vast.Instance.Image -and $state.instance_id -and [string]$state.instance_status -ne 'destroyed') {
    throw "Instance $($state.instance_id) was created from '$deploymentImage', but the current template is '$($config.Vast.Instance.Image)'. Keep managing the existing instance or destroy it before creating a PyTorch-based deployment; an instance image cannot be replaced in place."
}

Assert-CommandExists -Name 'ssh'
Assert-CommandExists -Name 'scp'
Write-Host '[local 1/5] Waiting for the Vast.ai instance and resolving its SSH endpoint...' -ForegroundColor Cyan
Wait-VastInstanceRunning -Config $config -InstanceId $state.instance_id | Out-Null
$endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
$sshCommon = @(Get-SshCommonArguments -Config $config)
Wait-VastSshReady -Config $config -Endpoint $endpoint

Write-Host '[local 2/5] Generating the remote deployment configuration...' -ForegroundColor Cyan
$remoteConfig = [ordered]@{
    schema_version = 2
    application = [ordered]@{
        type = $application.Type
    }
    pytorch = [ordered]@{
        python = [string]$config.PyTorch.Python
        minimum_cuda_version = [string]$config.PyTorch.MinimumCudaVersion
    }
    system = [ordered]@{
        packages = @($config.System.Packages)
    }
    comfyui = [ordered]@{
        repository = [string]$config.ComfyUI.Repository
        ref = [string]$config.ComfyUI.Ref
        root = [string]$config.ComfyUI.Root
        venv = [string]$config.ComfyUI.Venv
        python = [string]$config.ComfyUI.Python
        listen_host = [string]$config.ComfyUI.ListenHost
        port = [int]$config.ComfyUI.Port
        service_name = [string]$config.ComfyUI.ServiceName
        log_path = [string]$config.ComfyUI.LogPath
        extra_args = @($config.ComfyUI.ExtraArgs)
    }
    webui = [ordered]@{
        repository = [string]$config.WebUI.Repository
        ref = [string]$config.WebUI.Ref
        root = [string]$config.WebUI.Root
        venv = [string]$config.WebUI.Venv
        python = [string]$config.WebUI.Python
        python_version = [string]$config.WebUI.PythonVersion
        listen_host = [string]$config.WebUI.ListenHost
        port = [int]$config.WebUI.Port
        service_name = [string]$config.WebUI.ServiceName
        log_path = [string]$config.WebUI.LogPath
        model_root = [string]$config.WebUI.ModelRoot
        extra_args = @($config.WebUI.ExtraArgs)
    }
    anima = [ordered]@{
        variant = [string]$config.Anima.Variant
        workflow_url = [string]$config.Anima.WorkflowUrl
        workflow_file_name = [string]$config.Anima.WorkflowFileName
        models = @($config.Anima.Models)
        baseline = $config.Anima.Baseline
    }
    codex = [ordered]@{
        install = [bool]$config.Codex.Install
        installer_url = [string]$config.Codex.InstallerUrl
        project_root = [string]$config.Codex.ProjectRoot
        auth_mode = [string]$config.Codex.AuthMode
        api_key_environment_variable = [string]$config.Codex.ApiKeyEnvironmentVariable
        approval_policy = [string]$config.Codex.ApprovalPolicy
        sandbox_mode = [string]$config.Codex.SandboxMode
        model = [string]$config.Codex.Model
    }
}

$generatedConfig = Save-JsonFile -Value $remoteConfig -Path ([string]$config.Local.GeneratedRemoteConfigPath)
$remoteUploadDirectory = [string]$config.Local.RemoteUploadDirectory
$provisionScriptPath = if ($config.Local.ContainsKey('ProvisionScriptPath')) {
    Resolve-ProjectPath -Path ([string]$config.Local.ProvisionScriptPath)
} else {
    Join-Path $script:ProjectRoot 'remote/provision.sh'
}
$codexScriptPath = if ($config.Local.ContainsKey('CodexScriptPath')) {
    Resolve-ProjectPath -Path ([string]$config.Local.CodexScriptPath)
} else {
    Join-Path $script:ProjectRoot 'remote/configure-codex.sh'
}
$verifyScriptPath = Resolve-ProjectPath -Path 'remote/verify-deployment.sh'
foreach ($requiredScript in @($provisionScriptPath, $codexScriptPath, $verifyScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Remote script not found: $requiredScript"
    }
}

$target = "$($endpoint.User)@$($endpoint.Host)"
Write-Host "[local 3/5] Uploading deployment scripts to $target..." -ForegroundColor Cyan
Invoke-NativeCommandCheckedWithRetry -Command 'ssh' -Arguments ($sshCommon + @(
    '-p', [string]$endpoint.Port, $target, "mkdir -p '$remoteUploadDirectory/remote'"
)) -FailureMessage 'Could not create remote upload directory.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 60

$scpCommon = @()
for ($i = 0; $i -lt $sshCommon.Count; $i += 2) {
    $scpCommon += @($sshCommon[$i], $sshCommon[$i + 1])
}
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $provisionScriptPath, "${target}:$remoteUploadDirectory/remote/provision.sh"
)) -FailureMessage 'Uploading the remote provision script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $codexScriptPath, "${target}:$remoteUploadDirectory/remote/configure-codex.sh"
)) -FailureMessage 'Uploading the remote Codex script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $verifyScriptPath, "${target}:$remoteUploadDirectory/remote/verify-deployment.sh"
)) -FailureMessage 'Uploading the remote verification script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $generatedConfig, "${target}:$remoteUploadDirectory/remote-config.json"
)) -FailureMessage 'Uploading remote configuration failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120

Write-Host '[local 4/5] Running remote provisioning; model downloads can take a long time.' -ForegroundColor Cyan
Write-Host 'Progress and downloaded sizes will be printed below. Interrupted downloads resume from .part files.' -ForegroundColor DarkCyan
$remoteCommand = "bash '$remoteUploadDirectory/remote/provision.sh' '$remoteUploadDirectory/remote-config.json'"
try {
    Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($sshCommon + @(
        '-p', [string]$endpoint.Port, $target, $remoteCommand
    )) -FailureMessage 'Remote provisioning failed.'
}
catch {
    $state.provisioned = $false
    $state.last_error = $_.Exception.Message
    Save-DeploymentState -Config $config -State $state | Out-Null
    throw
}

Write-Host '[local 5/5] Remote verification passed; saving deployment state...' -ForegroundColor Cyan
$state.provisioned = $true
$state.provisioned_at = (Get-Date).ToUniversalTime().ToString('o')
$state.ssh_host = $endpoint.Host
$state.ssh_port = $endpoint.Port
$state.last_error = $null
Save-DeploymentState -Config $config -State $state | Out-Null

Write-Host "$($application.DisplayName) provisioning completed for instance $($state.instance_id)." -ForegroundColor Green
Write-Host "Open tunnel: .\scripts\Open-AppTunnel.ps1"
if ([bool]$config.Codex.Install) {
    Write-Host "Codex login: ssh $($endpoint.User)@$($endpoint.Host) -p $($endpoint.Port), then run codex login --device-auth"
}
