[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$StartIfStopped,
    [switch]$ShowOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$scriptsRoot = Join-Path $projectRoot 'scripts'
. (Join-Path $scriptsRoot 'Common.ps1')

function Get-SelectedDeployment {
    param([string]$RequestedConfigPath)

    if ($RequestedConfigPath) {
        return [pscustomobject]@{
            Deployment = 'custom'
            ConfigPath = Resolve-ProjectPath -Path $RequestedConfigPath
        }
    }

    $launcherPath = Resolve-ProjectPath -Path 'user-config/launcher.json'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw 'Deployment configuration has not been initialized. Run .\Start-VastAnima.ps1 first.'
    }

    $launcher = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $launcher.config_path) {
        throw "Launcher configuration does not contain config_path: $launcherPath"
    }

    $deployment = [string](Get-ObjectProperty -Object $launcher -Names @('deployment', 'profile') -Default 'pytorch-ui')
    return [pscustomobject]@{
        Deployment = $deployment
        ConfigPath = Resolve-ProjectPath -Path ([string]$launcher.config_path)
    }
}

function Get-LiveInstance {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $instance = Get-VastAccountInstance -Config $Config -InstanceId $InstanceId -TimeoutSeconds 30
    if ($null -eq $instance) { throw "Instance $InstanceId is no longer present in the Vast.ai account." }
    return $instance
}

function Format-OptionalUsd {
    param($Amount, [int]$Decimals = 4)

    if ($null -eq $Amount -or [string]::IsNullOrWhiteSpace([string]$Amount)) { return 'unknown' }
    return Format-UsdPrice -Amount ([double]$Amount) -Decimals $Decimals
}

function ConvertTo-ShellDisplayArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[\s'']') {
        return "'" + $Value.Replace("'", "''") + "'"
    }
    return $Value
}

function Get-RemoteInteractiveCommand {
    # Keep one named shell session so reconnecting after a network interruption
    # resumes the same remote terminal.
    return "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s anima; else exec /bin/bash -l; fi"
}

function Show-DeploymentConnectionSummary {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$LiveStatus,
        $Endpoint
    )

    $hourlyUsd = Get-ObjectProperty -Object $State -Names @('hourly_usd')
    $volumeMonthlyUsd = Get-ObjectProperty -Object $State -Names @('volume_monthly_usd')
    $combinedHourlyUsd = Get-ObjectProperty -Object $State -Names @('estimated_total_hourly_usd')
    $provisioned = [bool](Get-ObjectProperty -Object $State -Names @('provisioned') -Default $false)
    $application = Get-DeploymentApplication -Config $Config -State $State
    $deploymentImage = [string](Get-ObjectProperty -Object $State -Names @('deployment_image') -Default $Config.Vast.Instance.Image)

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ' Vast.ai instance / remote CLI' -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ("Deployment              : {0}" -f $Selection.Deployment)
    Write-Host ("Config                  : {0}" -f $Selection.ConfigPath)
    Write-Host ("Image                   : {0}" -f $deploymentImage)
    Write-Host ("Application             : {0}" -f $application.DisplayName)
    Write-Host ("Instance                : {0} ({1})" -f $State.instance_id, $LiveStatus)
    Write-Host ("GPU offer / machine     : {0} / {1}" -f $State.offer_id, $State.machine_id)
    Write-Host ("GPU                     : {0}" -f $State.gpu_name)
    Write-Host ("Instance price          : {0} USD/hour" -f (Format-OptionalUsd -Amount $hourlyUsd))
    if ($null -ne $State.volume_id) {
        Write-Host ("Volume                  : {0} ({1} GB, {2})" -f $State.volume_id, $Config.Vast.Volume.SizeGb, $State.volume_status)
        Write-Host ("Volume price estimate   : {0} USD/month" -f (Format-OptionalUsd -Amount $volumeMonthlyUsd -Decimals 2))
    } else {
        Write-Host ("Storage                 : instance disk only ({0} GB); no persistent volume" -f $Config.Vast.Instance.ContainerDiskGb)
    }
    Write-Host ("Combined rate estimate  : {0} USD/hour" -f (Format-OptionalUsd -Amount $combinedHourlyUsd))
    Write-Host ("Workspace               : {0}" -f $Config.Vast.Volume.MountPath)
    Write-Host ("Provisioned             : {0}" -f $provisioned)
    Write-Host ("Application remote      : {0}:{1}" -f $application.Settings.ListenHost, $application.RemotePort)
    Write-Host ("Application tunnel URL  : http://127.0.0.1:{0}" -f $application.LocalPort)
    Write-Host ("Codex project           : {0}" -f $Config.Codex.ProjectRoot)
    Write-Host ("Codex auth / approvals  : {0} / {1}" -f $Config.Codex.AuthMode, $Config.Codex.ApprovalPolicy)
    Write-Host ("Codex sandbox           : {0}" -f $Config.Codex.SandboxMode)

    if (-not $provisioned) {
        Write-Warning "Remote provisioning is incomplete. $($application.DisplayName) and Codex may not have been configured yet."
    }

    if ($null -ne $Endpoint) {
        $remoteInteractiveCommand = Get-RemoteInteractiveCommand
        $sshArguments = @(Get-SshCommonArguments -Config $Config) + @(
            '-tt', '-p', [string]$Endpoint.Port,
            "$($Endpoint.User)@$($Endpoint.Host)",
            $remoteInteractiveCommand
        )
        $sshCommand = 'ssh ' + (($sshArguments | ForEach-Object {
            ConvertTo-ShellDisplayArgument -Value ([string]$_)
        }) -join ' ')
        Write-Host ("SSH endpoint            : {0}@{1}:{2}" -f $Endpoint.User, $Endpoint.Host, $Endpoint.Port) -ForegroundColor Green
        Write-Host ("SSH command             : {0}" -f $sshCommand) -ForegroundColor Green
        Write-Host ("Remote checks           : supervisorctl status {0}; ss -lntp | grep {1}" -f $application.ServiceName, $application.RemotePort)
        Write-Host 'Remote workspace        : cd /workspace'
        Write-Host 'Codex login             : /workspace/bin/codex-login.sh'
        Write-Host 'Codex CLI               : /workspace/bin/run-codex.sh'
    }
}

$selection = Get-SelectedDeployment -RequestedConfigPath $ConfigPath
$config = Get-DeployConfig -ConfigPath $selection.ConfigPath
$state = Get-DeploymentState -Config $config

if ($null -eq $state.instance_id) {
    throw 'The selected deployment has no instance_id. Deploy an instance first.'
}
if ([string]$state.instance_status -eq 'destroyed') {
    throw "Instance $($state.instance_id) has already been destroyed."
}

Assert-CommandExists -Name 'ssh'
$instance = Get-LiveInstance -Config $config -InstanceId ([int64]$state.instance_id)
$liveStatus = [string](Get-ObjectProperty -Object $instance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')

if ($liveStatus -ne 'running') {
    Show-DeploymentConnectionSummary -Selection $selection -Config $config -State $state -LiveStatus $liveStatus -Endpoint $null
    if (-not $StartIfStopped) {
        throw "Instance $($state.instance_id) is '$liveStatus'. Re-run with -StartIfStopped to start this paid instance and connect."
    }

    Write-Host ''
    Write-Host "Starting existing instance $($state.instance_id); GPU billing will resume." -ForegroundColor Yellow
    & (Join-Path $scriptsRoot 'Start-VastInstance.ps1') -ConfigPath $selection.ConfigPath
    $state = Get-DeploymentState -Config $config
    $instance = Get-LiveInstance -Config $config -InstanceId ([int64]$state.instance_id)
    $liveStatus = [string](Get-ObjectProperty -Object $instance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
}

if ($liveStatus -ne 'running') {
    throw "Instance $($state.instance_id) did not reach running state; current status is '$liveStatus'."
}

$endpoint = Get-VastSshEndpoint -Config $config -InstanceId ([int64]$state.instance_id)
Show-DeploymentConnectionSummary -Selection $selection -Config $config -State $state -LiveStatus $liveStatus -Endpoint $endpoint

Write-Host ''
$application = Get-DeploymentApplication -Config $config -State $state
Write-Host "Remote $($application.DisplayName) / Codex verification:" -ForegroundColor Cyan
try {
    $verification = Invoke-RemoteDeploymentVerification -Config $config -Endpoint $endpoint
    if ($verification.ExitCode -ne 0) {
        Write-Warning "Remote deployment verification did not pass (exit $($verification.ExitCode))."
    }
}
catch {
    Write-Warning "Could not run remote deployment verification: $($_.Exception.Message)"
}

if ($ShowOnly) {
    exit 0
}

Write-Host ''
Write-Host 'Opening the interactive remote shell. Type exit to return to Windows.' -ForegroundColor Cyan
$sshArguments = @(Get-SshCommonArguments -Config $config) + @(
    '-tt', '-p', [string]$endpoint.Port,
    "$($endpoint.User)@$($endpoint.Host)",
    (Get-RemoteInteractiveCommand)
)
& ssh @sshArguments
if ($LASTEXITCODE -ne 0) {
    throw "SSH exited with code $LASTEXITCODE."
}
