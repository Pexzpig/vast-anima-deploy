[CmdletBinding()]
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath
$state = Get-DeploymentState -Config $config
Assert-CommandExists -Name 'ssh'

$endpoint = Get-VastSshEndpoint -Config $config -InstanceId $state.instance_id
$common = @(Get-SshCommonArguments -Config $config)
$localPort = [int]$config.Vast.Ssh.LocalComfyPort
$remotePort = [int]$config.ComfyUI.Port

Write-Host "Opening SSH tunnel. Keep this terminal open, then browse http://127.0.0.1:$localPort" -ForegroundColor Green
& ssh @common -p $endpoint.Port -N -L "${localPort}:127.0.0.1:${remotePort}" "$($endpoint.User)@$($endpoint.Host)"
if ($LASTEXITCODE -ne 0) { throw "SSH tunnel exited with code $LASTEXITCODE." }
