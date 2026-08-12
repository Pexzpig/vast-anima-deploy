[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
$application = Get-DeploymentApplication -Config $config -State $state

$state | Format-List | Out-Host
if ($null -ne $state.instance_id -and $state.instance_status -ne 'destroyed') {
    Write-Host "Reconciling tracked instance $($state.instance_id) with Vast.ai..." -ForegroundColor Cyan
    $liveInstance = Get-VastAccountInstance -Config $config -InstanceId $state.instance_id -TimeoutSeconds 30
    if ($null -eq $liveInstance) {
        Set-DeploymentInstanceDestroyed -Config $config -State $state | Out-Null
        Write-Warning "Instance $($state.instance_id) is no longer present in Vast.ai. Local state was updated to 'destroyed'."
        $liveStatus = 'destroyed'
    } else {
        $liveInstance | Format-List | Out-Host
        $liveStatus = [string](Get-ObjectProperty -Object $liveInstance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
        if ($liveStatus -and $liveStatus -ne 'unknown' -and [string]$state.instance_status -ne $liveStatus) {
            $state.instance_status = $liveStatus
            Save-DeploymentState -Config $config -State $state | Out-Null
            Write-Host "Local instance status was refreshed to '$liveStatus'." -ForegroundColor DarkCyan
        }
    }

    if ($liveStatus -eq 'running') {
        Write-Host ''
        Write-Host "Remote $($application.DisplayName) / Codex verification:" -ForegroundColor Cyan
        try {
            $endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
            $verification = Invoke-RemoteDeploymentVerification -Config $config -Endpoint $endpoint
            if ($verification.ExitCode -ne 0) {
                Write-Warning "Remote deployment verification did not pass (exit $($verification.ExitCode))."
            }
        }
        catch {
            Write-Warning "Could not run remote deployment verification: $($_.Exception.Message)"
        }
    }
}
if ($null -ne $state.volume_id -and $state.volume_status -ne 'deleted') {
    Invoke-VastText -Config $config -Arguments @('show', 'volumes') -TimeoutSeconds 30 | Out-Host
}
