[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$instances = @(
    [pscustomobject]@{
        id = 101; actual_status = 'running'; label = 'anima-pytorch-ui'; gpu_name = 'RTX 4090'
        image_uuid = 'vastai/pytorch:cuda-12.8.1-auto'; geolocation = 'US'; public_ipaddr = '203.0.113.10'; dph_total = 0.42
    },
    [pscustomobject]@{
        id = 102; actual_status = 'exited'; label = 'anima-pytorch-ui'; gpu_name = 'RTX 6000 Ada'
        image_uuid = 'vastai/pytorch:cuda-12.8.1-auto'; geolocation = 'DE'; ssh_host = 'ssh.example'; dph_total = 0.55
    }
)
$rows = @(ConvertTo-VastInstanceChoiceRows -Instances $instances)
if ($rows.Count -ne 2 -or $rows[0].choice -ne 1 -or $rows[0].status -ne 'running' -or
    $rows[0].gpu -ne 'RTX 4090' -or $rows[0].region -ne 'US' -or $rows[0].ip -ne '203.0.113.10') {
    throw 'Existing instance choice rows do not expose the required connection information.'
}
if ($rows[0].PSObject.Properties.Name -contains 'id' -or ($rows | Out-String) -match '\b101\b') {
    throw 'Existing instance IDs are exposed in the user-facing choice list.'
}

$validAttachment = [pscustomobject]@{
    schema_version = 1
    source = 'external_script_instance'
    instance_id = 101
    label = 'anima-pytorch-ui'
    application_type = 'comfyui'
    deployment_image = 'vastai/pytorch:cuda-12.8.1-auto'
    service_name = 'comfyui'
    listen_host = '127.0.0.1'
    remote_port = 18188
    local_port = 28188
    application_root = '/workspace/ComfyUI'
    ssh_host = 'ssh.example'
    ssh_port = 12345
    verified_at = '2026-08-13T00:00:00Z'
}
if ((Assert-AttachedInstanceState -State $validAttachment).application_type -ne 'comfyui') {
    throw 'A valid attachment state was rejected.'
}
$invalidAttachment = $validAttachment | Select-Object * -ExcludeProperty source
try {
    Assert-AttachedInstanceState -State $invalidAttachment | Out-Null
    throw 'Attachment state without a source was accepted.'
} catch {
    if ($_.Exception.Message -notmatch 'missing required') { throw }
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$connector = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Connect-VastExistingInstance.ps1') -Raw -Encoding UTF8
$entry = Get-Content -LiteralPath (Join-Path $projectRoot 'Start-VastAnima.ps1') -Raw -Encoding UTF8
foreach ($expected in @(
    'Get-VastAccountInstances',
    'Vast.Instance.Label',
    'vast-anima-deploy-manifest.json',
    'remote_root=/tmp/anima-vast-deploy',
    'verify-deployment.sh',
    'Save-AttachedInstanceState',
    'Stop-ConnectionStartedInstance',
    "[ValidateSet('Prompt', 'Shell', 'Tunnel')]",
    'tmux new-session -A -s anima',
    'ExitOnForwardFailure=yes'
)) {
    if (-not $connector.Contains($expected)) { throw "Existing instance connector is missing expected behavior: $expected" }
}
foreach ($forbidden in @('Get-DeploymentState', 'Save-DeploymentState', 'Destroy-VastInstance', 'Provision-Instance')) {
    if ($connector.Contains($forbidden)) { throw "Attachment connector incorrectly enters canonical deployment lifecycle: $forbidden" }
}
if (-not $entry.Contains("'12' = 'ConnectExisting'") -or -not $entry.Contains('Connect-VastExistingInstance.ps1')) {
    throw 'The main menu does not expose the isolated existing-instance connector.'
}
if ($connector.Contains("-match '(?i)ssh|") -or -not $connector.Contains('permission denied|publickey')) {
    throw 'Generic SSH readiness failures are being misreported as private-key authentication failures.'
}

Write-Host 'Isolated existing script instance connection checks passed.' -ForegroundColor Green
