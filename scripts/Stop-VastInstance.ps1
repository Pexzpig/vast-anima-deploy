[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
if ($null -eq $state.instance_id) { throw 'State contains no instance_id.' }
if ($state.instance_status -eq 'destroyed') { throw 'The tracked instance has already been destroyed.' }

Invoke-VastText -Config $config -Arguments @('stop', 'instance', [string]$state.instance_id, '--raw') | Out-Host
$state.instance_status = 'stopped'
Save-DeploymentState -Config $config -State $state | Out-Null
Write-Host "Instance $($state.instance_id) is stopped. Compute billing stops, but storage/volume billing continues." -ForegroundColor Yellow
