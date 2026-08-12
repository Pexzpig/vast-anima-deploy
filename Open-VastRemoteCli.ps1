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
            Profile = 'custom'
            ConfigPath = Resolve-ProjectPath -Path $RequestedConfigPath
        }
    }

    $launcherPath = Resolve-ProjectPath -Path 'user-config/launcher.json'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw 'Deployment profile has not been initialized. Run .\Start-VastAnima.ps1 first.'
    }

    $launcher = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $launcher.config_path) {
        throw "Launcher configuration does not contain config_path: $launcherPath"
    }

    $profile = [string](Get-ObjectProperty -Object $launcher -Names @('profile') -Default 'unknown')
    return [pscustomobject]@{
        Profile = $profile
        ConfigPath = Resolve-ProjectPath -Path ([string]$launcher.config_path)
    }
}

function Get-LiveInstance {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $response = Invoke-VastJson -Config $Config -Arguments @('show', 'instance', [string]$InstanceId, '--raw')
    $instances = @(ConvertTo-ObjectArray -Value $response -CandidateProperties @('instances'))
    if ($instances.Count -eq 0) {
        throw "Instance $InstanceId was not returned by Vast.ai."
    }
    return $instances[0]
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
    # The vastai/comfy login profile tries to attach an existing tmux session
    # and exits with "no sessions" on a new persistent volume. Create the
    # session when necessary and fall back to a normal login shell.
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
    $localComfyPort = [int]$Config.Vast.Ssh.LocalComfyPort
    $remoteComfyPort = [int]$Config.ComfyUI.Port

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ' Vast.ai instance / remote CLI' -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ("Profile                 : {0}" -f $Selection.Profile)
    Write-Host ("Config                  : {0}" -f $Selection.ConfigPath)
    Write-Host ("Image                   : {0}" -f $Config.Vast.Instance.Image)
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
    Write-Host ("Volume mount            : {0}" -f $Config.Vast.Volume.MountPath)
    Write-Host ("Provisioned             : {0}" -f $provisioned)
    Write-Host ("ComfyUI remote          : {0}:{1}" -f $Config.ComfyUI.ListenHost, $remoteComfyPort)
    Write-Host ("ComfyUI tunnel URL      : http://127.0.0.1:{0}" -f $localComfyPort)
    Write-Host ("Codex project           : {0}" -f $Config.Codex.ProjectRoot)
    Write-Host ("Codex auth / approvals  : {0} / {1}" -f $Config.Codex.AuthMode, $Config.Codex.ApprovalPolicy)
    Write-Host ("Codex sandbox           : {0}" -f $Config.Codex.SandboxMode)

    if (-not $provisioned) {
        Write-Warning 'Remote provisioning is incomplete. ComfyUI and Codex may not have been configured yet.'
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
        Write-Host ("Remote checks           : supervisorctl status comfyui; ss -lntp | grep {0}" -f $remoteComfyPort)
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
Write-Host 'Remote ComfyUI / Codex verification:' -ForegroundColor Cyan
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
