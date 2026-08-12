[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$instanceDiskArguments = @(Add-VastVolumeLinkArguments `
    -Arguments @('create', 'instance', '123', '--disk', '30') `
    -VolumeId $null `
    -MountPath '/workspace')
if ($instanceDiskArguments -contains '--link-volume' -or
    $instanceDiskArguments -contains '--mount-path') {
    throw 'Instance-disk deployment unexpectedly included persistent-volume arguments.'
}

$volumeArguments = @(Add-VastVolumeLinkArguments `
    -Arguments @('create', 'instance', '123', '--disk', '30') `
    -VolumeId 456 `
    -MountPath '/workspace')
if (($volumeArguments -join ' ') -notmatch '--link-volume 456 --mount-path /workspace$') {
    throw "Persistent-volume deployment did not include its link arguments: $($volumeArguments -join ' ')"
}

$deploymentScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\New-VastDeployment.ps1') -Raw -Encoding UTF8
foreach ($expected in @(
    "[ValidateSet('Prompt', 'Volume', 'InstanceDisk')]",
    'Select deployment storage',
    'Storage: instance disk only',
    "volume_status = if (`$usePersistentVolume) { 'pending' } else { 'disabled' }",
    "storage_mode = if (`$usePersistentVolume) { 'volume' } else { 'instance_disk' }"
)) {
    if (-not $deploymentScript.Contains($expected)) {
        throw "Deployment storage selection is missing expected behavior: $expected"
    }
}

Write-Host 'Optional persistent-volume and instance-disk deployment checks passed.' -ForegroundColor Green
