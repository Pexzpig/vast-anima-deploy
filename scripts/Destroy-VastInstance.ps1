[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
if ($null -eq $state.instance_id) { throw 'State contains no instance_id.' }
if ($state.instance_status -eq 'destroyed') { throw 'The tracked instance has already been destroyed.' }
$instanceId = [int64]$state.instance_id

Write-Host "Checking whether instance $instanceId still exists in the Vast.ai account..."
$remoteInstance = Get-VastAccountInstance -Config $config -InstanceId $instanceId -TimeoutSeconds 30
if ($null -eq $remoteInstance) {
    Set-DeploymentInstanceDestroyed -Config $config -State $state | Out-Null
    Write-Host "Instance $instanceId is already absent from Vast.ai. The local deployment state has been reconciled." -ForegroundColor Yellow
    if ($null -ne $state.volume_id -and [string]$state.volume_status -ne 'deleted') {
        Write-Host "Separately created volume $($state.volume_id) is still tracked and was not deleted." -ForegroundColor Yellow
    }
    return
}

if (-not $Force) {
    $confirmation = Read-Host "Destroying instance $instanceId is irreversible. Type DESTROY"
    if ($confirmation -cne 'DESTROY') { throw 'Destroy cancelled.' }
}

try {
    Invoke-VastText `
        -Config $config `
        -Arguments @('destroy', 'instance', [string]$instanceId, '--raw') `
        -TimeoutSeconds 45 | Out-Host
}
catch {
    if ($_.Exception.Message -notmatch '\[NATIVE_COMMAND_TIMEOUT\]') { throw }

    Write-Warning "The destroy request exceeded 45 seconds. Checking the account before deciding whether it failed."
    $remoteAfterTimeout = Get-VastAccountInstance -Config $config -InstanceId $instanceId -TimeoutSeconds 30
    if ($null -ne $remoteAfterTimeout) {
        throw "Destroy request timed out and instance $instanceId is still present in Vast.ai. Retry later or use the web console."
    }
}

Set-DeploymentInstanceDestroyed -Config $config -State $state | Out-Null
if ($null -ne $state.volume_id -and [string]$state.volume_status -ne 'deleted') {
    Write-Host "Instance $instanceId was destroyed. Separately created volume $($state.volume_id) is retained." -ForegroundColor Yellow
} else {
    Write-Host "Instance $instanceId was destroyed. It had no persistent volume; its instance-disk data is permanently lost." -ForegroundColor Yellow
}
