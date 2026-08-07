Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Get-DeployConfig {
    param([string]$ConfigPath = (Join-Path $script:ProjectRoot 'config.psd1'))

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration not found: $ConfigPath. Restore or create config.psd1 before continuing."
    }
    return Import-PowerShellDataFile -LiteralPath $ConfigPath
}

function Assert-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function ConvertFrom-LooseJson {
    param([Parameter(Mandatory = $true)][string]$Text)

    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                return $lines[$i] | ConvertFrom-Json
            }
            catch {
                continue
            }
        }
        throw "Vast CLI did not return parseable JSON. Output:`n$Text"
    }
}

function Invoke-VastText {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $cli = [string]$Config.Vast.Cli
    Assert-CommandExists -Name $cli
    $output = & $cli @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Vast CLI failed ($LASTEXITCODE): $cli $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Invoke-VastJson {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $text = Invoke-VastText -Config $Config -Arguments $Arguments
    return ConvertFrom-LooseJson -Text $text
}

function ConvertTo-ObjectArray {
    param($Value, [string[]]$CandidateProperties = @('offers', 'instances', 'volumes'))

    if ($null -eq $Value) { return @() }
    foreach ($property in $CandidateProperties) {
        if ($Value.PSObject.Properties.Name -contains $property) {
            return @($Value.$property)
        }
    }
    return @($Value)
}

function Get-ObjectProperty {
    param($Object, [Parameter(Mandatory = $true)][string[]]$Names, $Default = $null)

    foreach ($name in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value -and [string]$value -ne '') { return $value }
        }
    }
    return $Default
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolved = Resolve-ProjectPath -Path $Path
    $directory = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolved -Encoding UTF8
    return $resolved
}

function Get-DeploymentState {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $path = Resolve-ProjectPath -Path ([string]$Config.Local.StatePath)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Deployment state not found: $path. Run New-VastDeployment.ps1 first."
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-DeploymentState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    return Save-JsonFile -Value $State -Path ([string]$Config.Local.StatePath)
}

function Resolve-CreatedId {
    param([Parameter(Mandatory = $true)]$Response)

    $id = Get-ObjectProperty -Object $Response -Names @('new_contract', 'id', 'volume_id', 'instance_id')
    if ($null -eq $id) {
        throw "Could not find a created contract ID in response: $($Response | ConvertTo-Json -Depth 10)"
    }
    return [int64]$id
}

function ConvertTo-DockerEnvironmentString {
    param([Parameter(Mandatory = $true)][hashtable]$Environment)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in ($Environment.Keys | Sort-Object)) {
        $value = [string]$Environment[$key]
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid environment variable name: $key"
        }
        if ($value -match "[\r\n]") {
            throw "Environment variable '$key' contains a newline."
        }
        $escaped = $value.Replace('"', '\"')
        $parts.Add("-e $key=`"$escaped`"")
    }
    return ($parts -join ' ')
}

function Wait-VastInstanceRunning {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $timeout = [int]$Config.Vast.Instance.WaitTimeoutSeconds
    $poll = [int]$Config.Vast.Instance.PollIntervalSeconds
    $deadline = (Get-Date).AddSeconds($timeout)
    $fatalStates = @('exited', 'unknown', 'offline', 'error', 'failed')

    while ((Get-Date) -lt $deadline) {
        $instance = Invoke-VastJson -Config $Config -Arguments @('show', 'instance', [string]$InstanceId, '--raw')
        $items = ConvertTo-ObjectArray -Value $instance -CandidateProperties @('instances')
        if ($items.Count -eq 0) { throw "Instance $InstanceId was not returned by Vast." }
        $item = $items[0]
        $status = [string](Get-ObjectProperty -Object $item -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
        Write-Host "Instance $InstanceId status: $status"
        if ($status -eq 'running') { return $item }
        if ($fatalStates -contains $status) {
            throw "Instance $InstanceId entered terminal state '$status'. Inspect Vast logs and destroy/retry with another offer."
        }
        Start-Sleep -Seconds $poll
    }
    throw "Timed out after $timeout seconds waiting for instance $InstanceId."
}

function Wait-VastVolumeVisible {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$VolumeId,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $response = Invoke-VastJson -Config $Config -Arguments @('show', 'volumes', '--raw')
        $volumes = @(ConvertTo-ObjectArray -Value $response -CandidateProperties @('volumes'))
        $match = @($volumes | Where-Object { [int64](Get-ObjectProperty -Object $_ -Names @('id') -Default 0) -eq $VolumeId })
        if ($match.Count -gt 0) { return $match[0] }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for volume $VolumeId to become visible."
}

function Get-VastSshEndpoint {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $instanceResponse = Invoke-VastJson -Config $Config -Arguments @('show', 'instance', [string]$InstanceId, '--raw')
    $items = ConvertTo-ObjectArray -Value $instanceResponse -CandidateProperties @('instances')
    $instance = $items[0]
    $hostName = Get-ObjectProperty -Object $instance -Names @('ssh_host', 'public_ipaddr', 'public_ip')
    $port = Get-ObjectProperty -Object $instance -Names @('ssh_port')

    if ($null -eq $port -and $instance.PSObject.Properties.Name -contains 'ports') {
        $ports = $instance.ports
        foreach ($key in @('22/tcp', '22')) {
            if ($ports.PSObject.Properties.Name -contains $key) {
                $port = Get-ObjectProperty -Object $ports.$key -Names @('HostPort', 'host_port')
                break
            }
        }
    }

    if ($null -eq $hostName -or $null -eq $port) {
        $url = Invoke-VastText -Config $Config -Arguments @('ssh-url', [string]$InstanceId)
        if ($url -match 'ssh://(?:(?<user>[^@/]+)@)?(?<host>[^:/\s]+):(?<port>\d+)') {
            $hostName = $Matches.host
            $port = $Matches.port
        }
    }

    if ($null -eq $hostName -or $null -eq $port) {
        throw "Could not resolve SSH endpoint for instance $InstanceId."
    }

    return [pscustomobject]@{
        User = [string]$Config.Vast.Ssh.User
        Host = [string]$hostName
        Port = [int]$port
    }
}

function Get-SshCommonArguments {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $arguments = @(
        '-o', "StrictHostKeyChecking=$($Config.Vast.Ssh.StrictHostKeyChecking)",
        '-o', "ConnectTimeout=$($Config.Vast.Ssh.ConnectTimeoutSeconds)"
    )
    $identity = [string]$Config.Vast.Ssh.IdentityFile
    if ($identity) {
        $arguments += @('-i', $identity)
    }
    return $arguments
}
