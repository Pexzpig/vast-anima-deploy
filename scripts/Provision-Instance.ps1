[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Add-CurrentFeatureConfigurationDefaults `
    -Config (Get-DeployConfig -ConfigPath $ConfigPath) `
    -Template (Get-DeployConfig -ConfigPath 'config.psd1')
$state = Get-DeploymentState -Config $config
$application = Get-DeploymentApplication -Config $config -State $state
$deploymentImage = [string]$state.deployment_image
if ($deploymentImage -ne [string]$config.Vast.Instance.Image -and $state.instance_id -and [string]$state.instance_status -ne 'destroyed') {
    throw "Instance $($state.instance_id) was created from '$deploymentImage', but the current template is '$($config.Vast.Instance.Image)'. Keep managing the existing instance or destroy it before creating a PyTorch-based deployment; an instance image cannot be replaced in place."
}

Assert-CommandExists -Name 'ssh'
Assert-CommandExists -Name 'scp'

function New-RestrictedSecretFile {
    param([Parameter(Mandatory = $true)][string]$Value)

    $path = [System.IO.Path]::GetTempFileName()
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetOwner($identity)
        $security.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $security
        [System.IO.File]::WriteAllText($path, $Value + "`n", (New-Object System.Text.UTF8Encoding($false)))
        return $path
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}

Write-Host '[local 1/5] Waiting for the Vast.ai instance and resolving its SSH endpoint...' -ForegroundColor Cyan
Wait-VastInstanceRunning -Config $config -InstanceId $state.instance_id | Out-Null
$endpoint = Wait-VastSshReady -Config $config -InstanceId $state.instance_id
$sshCommon = @(Get-SshCommonArguments -Config $config)
$automatedSshCommon = $sshCommon + @('-o', 'LogLevel=QUIET')

Write-Host '[local 2/5] Generating the remote deployment configuration...' -ForegroundColor Cyan
$remoteConfig = [ordered]@{
    schema_version = 2
    deployment_image = $deploymentImage
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
        torch_version = [string]$config.ComfyUI.TorchVersion
        torchvision_version = [string]$config.ComfyUI.TorchvisionVersion
        torchaudio_version = [string]$config.ComfyUI.TorchaudioVersion
        torch_cuda_version = [string]$config.ComfyUI.TorchCudaVersion
        torch_index_url = [string]$config.ComfyUI.TorchIndexUrl
        listen_host = [string]$config.ComfyUI.ListenHost
        port = [int]$config.ComfyUI.Port
        local_port = [int]$config.ComfyUI.LocalPort
        service_name = [string]$config.ComfyUI.ServiceName
        log_path = [string]$config.ComfyUI.LogPath
        extra_args = @($config.ComfyUI.ExtraArgs)
    }
    webui = [ordered]@{
        repository = [string]$config.WebUI.Repository
        ref = [string]$config.WebUI.Ref
        commit = [string]$config.WebUI.Commit
        root = [string]$config.WebUI.Root
        venv = [string]$config.WebUI.Venv
        python = [string]$config.WebUI.Python
        python_version = [string]$config.WebUI.PythonVersion
        torch_version = [string]$config.WebUI.TorchVersion
        torchvision_version = [string]$config.WebUI.TorchvisionVersion
        torch_cuda_version = [string]$config.WebUI.TorchCudaVersion
        torch_index_url = [string]$config.WebUI.TorchIndexUrl
        listen_host = [string]$config.WebUI.ListenHost
        port = [int]$config.WebUI.Port
        local_port = [int]$config.WebUI.LocalPort
        service_name = [string]$config.WebUI.ServiceName
        log_path = [string]$config.WebUI.LogPath
        model_root = [string]$config.WebUI.ModelRoot
        extra_args = @($config.WebUI.ExtraArgs)
        localization = [string]$config.WebUI.Localization
        extensions = @($config.WebUI.Extensions)
    }
    anima = [ordered]@{
        variant = [string]$config.Anima.Variant
        workflow_url = [string]$config.Anima.WorkflowUrl
        workflow_sha256 = [string]$config.Anima.WorkflowSha256
        workflow_file_name = [string]$config.Anima.WorkflowFileName
        managed_workflow_file_name = [string]$config.Anima.ManagedWorkflowFileName
        hires_workflow_file_name = [string]$config.Anima.HiresWorkflowFileName
        models = @($config.Anima.Models)
        baseline = $config.Anima.Baseline
        turbo = [ordered]@{
            name = [string]$config.Anima.Turbo.Name
            url = [string]$config.Anima.Turbo.Url
            sha256 = [string]$config.Anima.Turbo.Sha256
            strength = [double]$config.Anima.Turbo.Strength
            steps = [int]$config.Anima.Turbo.Steps
            cfg = [double]$config.Anima.Turbo.Cfg
            enabled_by_default = [bool]$config.Anima.Turbo.EnabledByDefault
        }
        managed_loras = @($config.Anima.ManagedLoRAs)
        manual_lora_slots = [int]$config.Anima.ManualLoRASlots
        hires = [ordered]@{
            scale = [double]$config.Anima.Hires.Scale
            upscale_method = [string]$config.Anima.Hires.UpscaleMethod
            steps = [int]$config.Anima.Hires.Steps
            cfg = [double]$config.Anima.Hires.Cfg
            sampler = [string]$config.Anima.Hires.Sampler
            scheduler = [string]$config.Anima.Hires.Scheduler
            denoise = [double]$config.Anima.Hires.Denoise
        }
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
$provisionScriptPath = Resolve-ProjectPath -Path ([string]$config.Local.ProvisionScriptPath)
$codexScriptPath = Resolve-ProjectPath -Path ([string]$config.Local.CodexScriptPath)
$verifyScriptPath = Resolve-ProjectPath -Path 'remote/verify-deployment.sh'
$applicationConfigScriptPath = Resolve-ProjectPath -Path 'remote/configure-application.py'
foreach ($requiredScript in @($provisionScriptPath, $codexScriptPath, $verifyScriptPath, $applicationConfigScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Remote script not found: $requiredScript"
    }
}

$target = "$($endpoint.User)@$($endpoint.Host)"
Write-Host "[local 3/5] Uploading deployment scripts to $target..." -ForegroundColor Cyan
Invoke-NativeCommandCheckedWithRetry -Command 'ssh' -Arguments ($automatedSshCommon + @(
    '-T', '-n', '-p', [string]$endpoint.Port, $target, "mkdir -p '$remoteUploadDirectory/remote' && exit"
)) -FailureMessage 'Could not create remote upload directory.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 60 -Quiet

$scpCommon = @('-q') + $automatedSshCommon
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $provisionScriptPath, "${target}:$remoteUploadDirectory/remote/provision.sh"
)) -FailureMessage 'Uploading the remote provision script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120 -Quiet
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $codexScriptPath, "${target}:$remoteUploadDirectory/remote/configure-codex.sh"
)) -FailureMessage 'Uploading the remote Codex script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120 -Quiet
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $verifyScriptPath, "${target}:$remoteUploadDirectory/remote/verify-deployment.sh"
)) -FailureMessage 'Uploading the remote verification script failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120 -Quiet
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $applicationConfigScriptPath, "${target}:$remoteUploadDirectory/remote/configure-application.py"
)) -FailureMessage 'Uploading the remote application configurator failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120 -Quiet
Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $generatedConfig, "${target}:$remoteUploadDirectory/remote-config.json"
)) -FailureMessage 'Uploading remote configuration failed.' -Attempts 4 -DelaySeconds 5 -TimeoutSeconds 120 -Quiet

Write-Host '[local 4/5] Running remote provisioning; model downloads can take a long time.' -ForegroundColor Cyan
Write-Host 'Progress and downloaded sizes will be printed below. Interrupted downloads resume from .part files.' -ForegroundColor DarkCyan
$remoteCommand = "bash '$remoteUploadDirectory/remote/provision.sh' '$remoteUploadDirectory/remote-config.json'"
$localCivitaiSecret = $null
$remoteCivitaiSecretUploaded = $false
try {
    $enabledCivitaiLoRAs = @($config.Anima.ManagedLoRAs | Where-Object { [bool]$_.Enabled -and [string]$_.Source -eq 'civitai' })
    if ($enabledCivitaiLoRAs.Count -gt 0) {
        $tokenEnvironmentVariable = [string]$config.Secrets.CivitaiTokenEnvironmentVariable
        $civitaiToken = [Environment]::GetEnvironmentVariable($tokenEnvironmentVariable, 'Process')
        if ($civitaiToken) {
            if ($civitaiToken -notmatch '^[A-Za-z0-9._-]+$') { throw "$tokenEnvironmentVariable contains unsupported characters." }
            try {
                $localCivitaiSecret = New-RestrictedSecretFile -Value $civitaiToken
            } finally {
                $civitaiToken = $null
            }
            Invoke-NativeCommandCheckedWithRetry -Command 'scp' -Arguments ($scpCommon + @(
                '-P', [string]$endpoint.Port, $localCivitaiSecret, "${target}:$remoteUploadDirectory/.civitai-token.upload"
            )) -FailureMessage 'Uploading the temporary Civitai credential failed.' -Attempts 3 -DelaySeconds 3 -TimeoutSeconds 60 -Quiet
            $remoteCivitaiSecretUploaded = $true
            Invoke-NativeCommandCheckedWithRetry -Command 'ssh' -Arguments ($automatedSshCommon + @(
                '-T', '-n', '-p', [string]$endpoint.Port, $target,
                "umask 077 && mv '$remoteUploadDirectory/.civitai-token.upload' '$remoteUploadDirectory/.civitai-token'"
            )) -FailureMessage 'Securing the temporary Civitai credential failed.' -Attempts 3 -DelaySeconds 3 -TimeoutSeconds 60 -Quiet
        }
    }
    Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($automatedSshCommon + @(
        '-T', '-n', '-p', [string]$endpoint.Port, $target, $remoteCommand
    )) -FailureMessage 'Remote provisioning failed.'
}
catch {
    $state.provisioned = $false
    $state.last_error = $_.Exception.Message
    Save-DeploymentState -Config $config -State $state | Out-Null
    throw
}
finally {
    if ($localCivitaiSecret -and (Test-Path -LiteralPath $localCivitaiSecret)) {
        Remove-Item -LiteralPath $localCivitaiSecret -Force -ErrorAction SilentlyContinue
    }
    if ($remoteCivitaiSecretUploaded) {
        try {
            Invoke-NativeCommandCapture -Command 'ssh' -Arguments ($automatedSshCommon + @(
                '-T', '-n', '-p', [string]$endpoint.Port, $target,
                "rm -f -- '$remoteUploadDirectory/.civitai-token' '$remoteUploadDirectory/.civitai-curl.conf' '$remoteUploadDirectory/.civitai-token.upload'"
            )) -TimeoutSeconds 30 | Out-Null
        } catch {}
    }
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
