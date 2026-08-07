[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config

$state | Format-List | Out-Host
if ($null -ne $state.instance_id -and $state.instance_status -ne 'destroyed') {
    Invoke-VastText -Config $config -Arguments @('show', 'instance', [string]$state.instance_id) | Out-Host
}
if ($null -ne $state.volume_id -and $state.volume_status -ne 'deleted') {
    Invoke-VastText -Config $config -Arguments @('show', 'volumes') | Out-Host
}
