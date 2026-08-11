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

function ConvertTo-HashtableDeep {
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in $InputObject.Keys) {
                $result[[string]$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
            }
            return $result
        }

        if ($InputObject -is [pscustomobject]) {
            $result = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
            }
            return $result
        }

        if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
            $items = @()
            foreach ($item in $InputObject) {
                $items += ,(ConvertTo-HashtableDeep -InputObject $item)
            }
            return ,$items
        }

        return $InputObject
    }
}

function Get-DeployConfig {
    param([string]$ConfigPath = (Join-Path $script:ProjectRoot 'config.psd1'))

    $resolvedPath = Resolve-ProjectPath -Path $ConfigPath
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "Configuration not found: $resolvedPath. Restore or create config.psd1 before continuing."
    }

    if ([System.IO.Path]::GetExtension($resolvedPath) -ieq '.json') {
        $json = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ConvertTo-HashtableDeep -InputObject $json
    }

    return Import-PowerShellDataFile -LiteralPath $resolvedPath
}

function Assert-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-NativeCommandCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    Assert-CommandExists -Name $Command

    # Windows PowerShell 5.1 turns native stderr into non-terminating
    # NativeCommandError records. With the project-wide Stop preference those
    # records would terminate execution before callers can inspect EXITCODE.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rawOutput = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $output = @($rawOutput | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $output
        Text = ($output -join "`n").Trim()
    }
}

function Invoke-NativeCommandChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    Assert-CommandExists -Name $Command

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1 | ForEach-Object { Write-Host ($_.ToString()) }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "$FailureMessage Native command exited with code $exitCode."
    }
}

function Test-VastAuthentication {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    $result = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('show', 'user', '--raw')
    return ($result.ExitCode -eq 0)
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
    $result = Invoke-NativeCommandCapture -Command $cli -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "Vast CLI failed ($($result.ExitCode)): $cli $($Arguments -join ' ')`n$($result.Text)"
    }
    return $result.Text
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
