[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
$application = Get-DeploymentApplication -Config $config -State $state
Assert-CommandExists -Name 'ssh'

$endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
$common = @(Get-SshCommonArguments -Config $config)
$localPort = $application.LocalPort
$remotePort = $application.RemotePort

Write-Host "Opening $($application.DisplayName) SSH tunnel." -ForegroundColor Green
Write-Host "Keep this terminal open, then browse http://127.0.0.1:$localPort" -ForegroundColor Green
Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($common + @(
    '-p', [string]$endpoint.Port,
    '-N', '-L', "${localPort}:127.0.0.1:${remotePort}",
    "$($endpoint.User)@$($endpoint.Host)"
)) -FailureMessage "$($application.DisplayName) SSH tunnel failed."
