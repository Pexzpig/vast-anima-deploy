[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config

$state | Format-List | Out-Host
if ($null -ne $state.instance_id -and $state.instance_status -ne 'destroyed') {
    $instanceText = Invoke-VastText -Config $config -Arguments @('show', 'instance', [string]$state.instance_id, '--raw')
    $instanceText | Out-Host
    $instanceResponse = ConvertFrom-LooseJson -Text $instanceText
    $instances = @(ConvertTo-ObjectArray -Value $instanceResponse -CandidateProperties @('instances'))
    $liveStatus = if ($instances.Count -gt 0) {
        [string](Get-ObjectProperty -Object $instances[0] -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
    } else {
        'unknown'
    }

    if ($liveStatus -eq 'running') {
        Write-Host ''
        Write-Host 'Remote ComfyUI / Codex verification:' -ForegroundColor Cyan
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
    Invoke-VastText -Config $config -Arguments @('show', 'volumes') | Out-Host
}
