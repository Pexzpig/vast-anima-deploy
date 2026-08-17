[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$config = @{
    Vast = @{
        Ssh = @{
            User = 'root'
            IdentityFile = ''
            StrictHostKeyChecking = 'accept-new'
            ConnectTimeoutSeconds = 1
            ReadyTimeoutSeconds = 900
            ReadyPollIntervalSeconds = 10
        }
    }
}

$script:statusMessages = @()
function Write-TransientStatus {
    param(
        [string]$Message,
        [switch]$Complete,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::DarkCyan
    )
    $script:statusMessages += $Message
}
function Assert-CommandExists { param([string]$Name) }
function Get-SshCommonArguments { param([hashtable]$Config); return @('-o', 'BatchMode=yes') }
function Start-Sleep { param([int]$Seconds) }
$script:sshUrlCalls = 0
function Invoke-VastText {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    $script:sshUrlCalls++
    throw 'SSH endpoint is not published yet.'
}

$script:instanceResponses = [System.Collections.Queue]::new()
$script:instanceResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 7001; actual_status = $null; intended_status = 'running'; cur_state = 'running'; next_state = 'running'; status_msg = 'pulling image'
    }
})
$script:instanceResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 7001; actual_status = 'running'; intended_status = 'running'; cur_state = 'running'; next_state = 'running'
        status_msg = 'container running; SSH bootstrap pending'; ssh_host = 'old.ssh.example'; ssh_port = 10001
    }
})
$script:instanceResponses.Enqueue([pscustomobject]@{
    instances = [pscustomobject]@{
        id = 7001; actual_status = 'running'; intended_status = 'running'; cur_state = 'running'; next_state = 'running'
        status_msg = 'success, running image/ssh'; ssh_host = 'new.ssh.example'; ssh_port = 10002
    }
})
$script:sshResults = [System.Collections.Queue]::new()
$script:sshResults.Enqueue([pscustomobject]@{ ExitCode = 255; Text = 'Connection closed'; Output = @('Connection closed') })
$script:sshResults.Enqueue([pscustomobject]@{ ExitCode = 0; Text = 'SSH_READY'; Output = @('SSH_READY') })
$script:sshArguments = @()
function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    if ($script:instanceResponses.Count -eq 0) { throw 'Unexpected extra Vast status query.' }
    return $script:instanceResponses.Dequeue()
}
function Invoke-NativeCommandCapture {
    param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds)
    $script:sshArguments += ,@($Arguments)
    if ($script:sshResults.Count -eq 0) { throw 'Unexpected extra SSH probe.' }
    return $script:sshResults.Dequeue()
}

$endpoint = Wait-VastSshReady -Config $config -InstanceId 7001 -TimeoutSeconds 5 -PollIntervalSeconds 1
if ($endpoint.Host -ne 'new.ssh.example' -or $endpoint.Port -ne 10002 -or $script:sshArguments.Count -ne 2 -or $script:sshUrlCalls -ne 0) {
    throw 'SSH readiness did not wait for running status or return the latest endpoint.'
}
if (-not @($script:statusMessages | Where-Object { $_ -match 'Vast=provisioning, endpoint=pending' })) {
    throw 'A null Vast actual_status was not displayed as provisioning with a pending endpoint.'
}
if (($script:sshArguments[0] -join ' ') -notmatch 'old\.ssh\.example' -or
    ($script:sshArguments[1] -join ' ') -notmatch 'new\.ssh\.example') {
    throw 'SSH probes did not follow the endpoint reported by each Vast status response.'
}

$script:sshResults = [System.Collections.Queue]::new()
$script:sshResults.Enqueue([pscustomobject]@{ ExitCode = 0; Text = 'SSH_READY'; Output = @('SSH_READY') })
function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    return [pscustomobject]@{
        instances = [pscustomobject]@{
            id = 7005; actual_status = 'running'; intended_status = 'running'; cur_state = 'running'; next_state = 'running'
        }
    }
}
function Invoke-VastText {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    return 'ssh://root@fallback.ssh.example:10005'
}
$fallbackEndpoint = Wait-VastSshReady -Config $config -InstanceId 7005 -TimeoutSeconds 5 -PollIntervalSeconds 1
if ($fallbackEndpoint.Host -ne 'fallback.ssh.example' -or $fallbackEndpoint.Port -ne 10005) {
    throw 'A running instance without embedded SSH fields did not use the Vast ssh-url fallback.'
}

$script:statusMessages = @()
$script:apiCalls = 0
$script:sshResults = [System.Collections.Queue]::new()
$script:sshResults.Enqueue([pscustomobject]@{ ExitCode = 0; Text = 'SSH_READY'; Output = @('SSH_READY') })
function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    $script:apiCalls++
    if ($script:apiCalls -eq 1) { throw 'temporary Vast API timeout' }
    return [pscustomobject]@{
        instances = [pscustomobject]@{
            id = 7002; actual_status = 'running'; intended_status = 'running'; cur_state = 'running'; next_state = 'running'
            ssh_host = 'recovered.ssh.example'; ssh_port = 10003
        }
    }
}
$recoveredEndpoint = Wait-VastSshReady -Config $config -InstanceId 7002 -TimeoutSeconds 5 -PollIntervalSeconds 1
if ($script:apiCalls -ne 2 -or $recoveredEndpoint.Host -ne 'recovered.ssh.example' -or
    -not @($script:statusMessages | Where-Object { $_ -match 'status query unavailable' })) {
    throw 'A transient Vast API failure was not tolerated before SSH became ready.'
}

function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    return [pscustomobject]@{
        instances = [pscustomobject]@{
            id = 7003; actual_status = 'exited'; intended_status = 'running'; cur_state = 'stopped'; next_state = 'running'
            status_msg = 'container entrypoint failed'
        }
    }
}
$terminalCaught = $false
try {
    Wait-VastSshReady -Config $config -InstanceId 7003 -TimeoutSeconds 5 -PollIntervalSeconds 1 -TerminalStateGraceSeconds 0 | Out-Null
} catch {
    $terminalCaught = $true
    if ($_.Exception.Message -notmatch 'container entrypoint failed' -or
        $_.Exception.Message -notmatch 'vastai logs 7003') {
        throw "Terminal Vast status did not include actionable diagnostics: $($_.Exception.Message)"
    }
}
if (-not $terminalCaught) { throw 'A persistent exited state was incorrectly allowed to continue waiting for SSH.' }

function Invoke-VastJson {
    param([hashtable]$Config, [string[]]$Arguments, [int]$TimeoutSeconds)
    return [pscustomobject]@{
        instances = [pscustomobject]@{
            id = 7004; actual_status = 'running'; intended_status = 'running'; cur_state = 'running'; next_state = 'running'
            status_msg = 'SSH still starting'; ssh_host = 'timeout.ssh.example'; ssh_port = 10004
        }
    }
}
function Invoke-NativeCommandCapture {
    param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds)
    return [pscustomobject]@{ ExitCode = 255; Text = 'Connection timed out'; Output = @('Connection timed out') }
}
function Start-Sleep {
    param([int]$Seconds)
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 100
}
$timeoutCaught = $false
try {
    Wait-VastSshReady -Config $config -InstanceId 7004 -TimeoutSeconds 1 -PollIntervalSeconds 1 | Out-Null
} catch {
    $timeoutCaught = $true
    if ($_.Exception.Message -notmatch 'Last Vast state: actual=running' -or
        $_.Exception.Message -notmatch 'Connection timed out' -or
        $_.Exception.Message -notmatch 'vastai show instance 7004 --raw') {
        throw "SSH timeout did not include Vast and SSH diagnostics: $($_.Exception.Message)"
    }
}
if (-not $timeoutCaught) { throw 'SSH readiness did not honor its total timeout.' }

$template = Get-DeployConfig -ConfigPath 'config.psd1'
if ($template.Vast.Ssh.ReadyTimeoutSeconds -ne 900 -or $template.Vast.Ssh.ReadyPollIntervalSeconds -ne 10) {
    throw 'The canonical SSH readiness defaults are not 900/10 seconds.'
}

foreach ($relativePath in @(
    '..\scripts\New-VastDeployment.ps1',
    '..\scripts\Provision-Instance.ps1',
    '..\scripts\Connect-VastExistingInstance.ps1'
)) {
    $scriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot $relativePath) -Raw -Encoding UTF8
    if ($scriptText -notmatch '\$endpoint\s*=\s*Wait-VastSshReady\s+-Config\s+\$config\s+-InstanceId' -or
        $scriptText -match 'Wait-VastSshReady[^\r\n]+-Endpoint') {
        throw "SSH readiness call site does not capture a fresh endpoint: $relativePath"
    }
}

$commonText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Common.ps1') -Raw -Encoding UTF8
if ($commonText -notmatch 'Waiting for SSH: Vast=\$lastStatus, endpoint=\$endpointText' -or
    $commonText -match 'SSH is not ready yet \(attempt') {
    throw 'SSH readiness output is not using the compact status-aware single-line format.'
}

Write-Host 'Status-aware Vast SSH readiness checks passed.' -ForegroundColor Green
exit 0
