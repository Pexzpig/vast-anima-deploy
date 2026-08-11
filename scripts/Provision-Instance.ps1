[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config

Assert-CommandExists -Name 'ssh'
Assert-CommandExists -Name 'scp'
Wait-VastInstanceRunning -Config $config -InstanceId $state.instance_id | Out-Null
$endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
$sshCommon = @(Get-SshCommonArguments -Config $config)

$remoteConfig = [ordered]@{
    schema_version = 1
    comfyui = [ordered]@{
        installation_mode = if ($config.ComfyUI.ContainsKey('InstallationMode')) { [string]$config.ComfyUI.InstallationMode } else { 'managed' }
        repository = [string]$config.ComfyUI.Repository
        ref = [string]$config.ComfyUI.Ref
        root = [string]$config.ComfyUI.Root
        python = [string]$config.ComfyUI.Python
        uv = [string]$config.ComfyUI.Uv
        listen_host = [string]$config.ComfyUI.ListenHost
        port = [int]$config.ComfyUI.Port
        service_name = [string]$config.ComfyUI.ServiceName
        log_path = [string]$config.ComfyUI.LogPath
        extra_args = @($config.ComfyUI.ExtraArgs)
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
foreach ($requiredScript in @($provisionScriptPath, $codexScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Remote script not found: $requiredScript"
    }
}

$target = "$($endpoint.User)@$($endpoint.Host)"
Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($sshCommon + @(
    '-p', [string]$endpoint.Port, $target, "mkdir -p '$remoteUploadDirectory/remote'"
)) -FailureMessage 'Could not create remote upload directory.'

$scpCommon = @()
for ($i = 0; $i -lt $sshCommon.Count; $i += 2) {
    $scpCommon += @($sshCommon[$i], $sshCommon[$i + 1])
}
Invoke-NativeCommandChecked -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $provisionScriptPath, "${target}:$remoteUploadDirectory/remote/provision.sh"
)) -FailureMessage 'Uploading the remote provision script failed.'
Invoke-NativeCommandChecked -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $codexScriptPath, "${target}:$remoteUploadDirectory/remote/configure-codex.sh"
)) -FailureMessage 'Uploading the remote Codex script failed.'
Invoke-NativeCommandChecked -Command 'scp' -Arguments ($scpCommon + @(
    '-P', [string]$endpoint.Port, $generatedConfig, "${target}:$remoteUploadDirectory/remote-config.json"
)) -FailureMessage 'Uploading remote configuration failed.'

$remoteCommand = "bash '$remoteUploadDirectory/remote/provision.sh' '$remoteUploadDirectory/remote-config.json'"
Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($sshCommon + @(
    '-p', [string]$endpoint.Port, $target, $remoteCommand
)) -FailureMessage 'Remote provisioning failed.'

$state.provisioned = $true
$state.provisioned_at = (Get-Date).ToUniversalTime().ToString('o')
$state.ssh_host = $endpoint.Host
$state.ssh_port = $endpoint.Port
Save-DeploymentState -Config $config -State $state | Out-Null

Write-Host "Remote provisioning completed for instance $($state.instance_id)." -ForegroundColor Green
Write-Host "Open tunnel: .\scripts\Open-ComfyUITunnel.ps1"
if ([bool]$config.Codex.Install) {
    Write-Host "Codex login: ssh $($endpoint.User)@$($endpoint.Host) -p $($endpoint.Port), then run codex login --device-auth"
}
