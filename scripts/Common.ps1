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

function Resolve-SshIdentityPath {
    param([string]$Path)

    if (-not $Path) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') { return [Environment]::GetFolderPath('UserProfile') }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        return Join-Path ([Environment]::GetFolderPath('UserProfile')) $expanded.Substring(2)
    }
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return Resolve-ProjectPath -Path $expanded
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

function ConvertTo-NativeArgumentString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }

    # Quote according to the Windows CommandLineToArgvW rules. This preserves
    # embedded spaces and quotes when ProcessStartInfo is used for timeouts.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-NativeExecutableCaptureWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][ValidateRange(1, 3600)][int]$TimeoutSeconds
    )

    $commandInfo = Get-Command $Command -ErrorAction Stop
    if ($commandInfo.CommandType -ne 'Application') {
        throw "[NATIVE_TIMEOUT_UNSUPPORTED] Timed execution requires an executable command, but '$Command' resolved to $($commandInfo.CommandType)."
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $commandInfo.Source
    $startInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-NativeArgumentString -Argument ([string]$_)
    }) -join ' ')
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start native command '$Command'."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            $process.WaitForExit()
            throw "[NATIVE_COMMAND_TIMEOUT] Command '$Command' exceeded $TimeoutSeconds seconds and was terminated."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $text = (@($stdout.Trim(), $stderr.Trim()) | Where-Object { $_ }) -join "`n"
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
            Text = $text.Trim()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeCommandCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )

    Assert-CommandExists -Name $Command

    if ($TimeoutSeconds -gt 0) {
        return Invoke-NativeExecutableCaptureWithTimeout `
            -Command $Command `
            -Arguments $Arguments `
            -TimeoutSeconds $TimeoutSeconds
    }

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

function Invoke-NativeCommandCheckedWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [ValidateRange(1, 20)][int]$Attempts = 4,
        [ValidateRange(0, 300)][int]$DelaySeconds = 5,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )

    $lastResult = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $lastResult = Invoke-NativeCommandCapture `
            -Command $Command `
            -Arguments $Arguments `
            -TimeoutSeconds $TimeoutSeconds
        $lastResult.Output | ForEach-Object { Write-Host $_ }
        if ($lastResult.ExitCode -eq 0) { return }

        if ($attempt -lt $Attempts) {
            Write-Warning "$Command failed with exit code $($lastResult.ExitCode) (attempt $attempt/$Attempts). Retrying in $DelaySeconds seconds..."
            if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        }
    }

    throw "$FailureMessage Native command failed after $Attempts attempts with exit code $($lastResult.ExitCode).`n$($lastResult.Text)"
}

function Get-VastAuthenticationStatus {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    $result = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('show', 'user', '--raw')
    $response = $null
    if ($result.Text) {
        try { $response = ConvertFrom-LooseJson -Text $result.Text } catch {}
    }

    $reportedError = if ($null -ne $response) {
        [bool](Get-ObjectProperty -Object $response -Names @('error', 'success') -Default $false)
    } else {
        $false
    }
    if ($null -ne $response -and $response.PSObject.Properties.Name -contains 'success') {
        $reportedError = -not [bool]$response.success
    }

    $userId = Get-ObjectProperty -Object $response -Names @('id', 'user_id')
    $email = Get-ObjectProperty -Object $response -Names @('email', 'username')
    if ($result.ExitCode -eq 0 -and -not $reportedError -and ($null -ne $userId -or $null -ne $email)) {
        return [pscustomobject]@{
            Authenticated = $true
            UserId = $userId
            Email = $email
            User = $response
            RawText = $result.Text
            Reason = 'Authenticated'
        }
    }

    $statusCode = Get-ObjectProperty -Object $response -Names @('status_code', 'status') -Default 0
    $authenticationFailure = ([string]$statusCode -in @('401', '403')) -or
        ($result.Text -match '(?i)requires login|not logged|unauthori[sz]ed|forbidden|invalid.*api.?key')
    if ($authenticationFailure) {
        return [pscustomobject]@{
            Authenticated = $false
            UserId = $null
            Email = $null
            User = $response
            RawText = $result.Text
            Reason = 'AuthenticationRequired'
        }
    }

    throw "[VAST_AUTH_CHECK_FAILED] Could not verify Vast CLI authentication (exit code $($result.ExitCode)). Check the network and CLI configuration.`n$($result.Text)"
}

function Test-VastAuthentication {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    return [bool](Get-VastAuthenticationStatus -CliPath $CliPath).Authenticated
}

function Test-SshPublicKeyRegistered {
    param(
        [Parameter(Mandatory = $true)][string]$PublicKeyPath,
        [Parameter(Mandatory = $true)][string]$AccountText
    )

    if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) { return $false }
    $parts = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+'
    if ($parts.Count -lt 2 -or -not $parts[1]) { return $false }
    return ($AccountText -match [regex]::Escape($parts[1]))
}

function Get-SshPublicKeyContent {
    param([Parameter(Mandatory = $true)][string]$PublicKeyPath)

    if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        throw "SSH public key file was not found: $PublicKeyPath"
    }

    $content = (Get-Content -LiteralPath $PublicKeyPath -Raw -Encoding ASCII).Trim()
    $lines = @($content -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "SSH public key must contain exactly one non-empty line: $PublicKeyPath"
    }

    $parts = $content -split '\s+'
    $validType = $parts.Count -ge 2 -and $parts[0] -match '^(ssh-|ecdsa-|sk-)'
    $validBody = $parts.Count -ge 2 -and $parts[1] -match '^[A-Za-z0-9+/]+={0,3}$'
    if (-not $validType -or -not $validBody) {
        throw "SSH public key is not in OpenSSH public-key format: $PublicKeyPath"
    }
    return $content
}

function Get-VastSshKeyCreateArguments {
    param([Parameter(Mandatory = $true)][string]$PublicKeyPath)

    # Current Vast CLI releases pass a supplied argument directly to the API
    # even though the CLI documentation describes it as a .pub file path.
    # Supplying the actual OpenSSH key text works with both behaviors.
    $publicKeyContent = Get-SshPublicKeyContent -PublicKeyPath $PublicKeyPath
    return @('create', 'ssh-key', $publicKeyContent, '-y')
}

function Test-SshKeyPairUsable {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateKeyPath,
        [Parameter(Mandatory = $true)][string]$PublicKeyPath
    )

    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
        return $false
    }
    # -P with an empty passphrase prevents an interactive prompt. A protected
    # or mismatched key is not suitable for unattended deployment.
    $derived = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @(
        '-y', '-P', '""', '-f', $PrivateKeyPath
    )
    if ($derived.ExitCode -ne 0) { return $false }
    $derivedParts = $derived.Text.Trim() -split '\s+'
    $publicParts = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+'
    return ($derivedParts.Count -ge 2 -and $publicParts.Count -ge 2 -and $derivedParts[1] -eq $publicParts[1])
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )

    $cli = [string]$Config.Vast.Cli
    Assert-CommandExists -Name $cli
    $result = Invoke-NativeCommandCapture -Command $cli -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "Vast CLI failed ($($result.ExitCode)): $cli $($Arguments -join ' ')`n$($result.Text)"
    }
    return $result.Text
}

function Invoke-VastJson {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )

    $text = Invoke-VastText -Config $Config -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
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

function Get-DeploymentApplication {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        $State
    )

    $configuredDefault = if ($Config.ContainsKey('Application') -and $Config.Application.ContainsKey('DefaultType')) {
        [string]$Config.Application.DefaultType
    } else {
        'comfyui'
    }
    $type = [string](Get-ObjectProperty -Object $State -Names @('application_type') -Default $configuredDefault)
    $type = $type.Trim().ToLowerInvariant()

    switch ($type) {
        'comfyui' {
            $settings = $Config.ComfyUI
            return [pscustomobject]@{
                Type = 'comfyui'
                DisplayName = 'ComfyUI'
                Settings = $settings
                RemotePort = [int]$settings.Port
                LocalPort = [int]$settings.LocalPort
                ServiceName = [string]$settings.ServiceName
                HealthPath = '/system_stats'
            }
        }
        'webui' {
            if (-not $Config.ContainsKey('WebUI')) { throw 'WebUI configuration is missing.' }
            $settings = $Config.WebUI
            return [pscustomobject]@{
                Type = 'webui'
                DisplayName = 'Forge Classic WebUI'
                Settings = $settings
                RemotePort = [int]$settings.Port
                LocalPort = [int]$settings.LocalPort
                ServiceName = [string]$settings.ServiceName
                HealthPath = '/'
            }
        }
        default { throw "Unsupported deployment application type: $type" }
    }
}

function Find-VastInstanceInResponse {
    param(
        $Response,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $instances = @(ConvertTo-ObjectArray -Value $Response -CandidateProperties @('instances'))
    $matches = @($instances | Where-Object {
        [int64](Get-ObjectProperty -Object $_ -Names @('id', 'instance_id', 'contract_id') -Default 0) -eq $InstanceId
    })
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-VastAccountInstance {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30
    )

    # Listing the account's active instances is intentionally used instead of
    # `show instance ID`: a deleted ID can return a CLI/API error, while an
    # absent list entry cleanly represents a resource deleted in the web UI.
    $response = Invoke-VastJson `
        -Config $Config `
        -Arguments @('show', 'instances', '--raw') `
        -TimeoutSeconds $TimeoutSeconds

    if ($null -ne $response) {
        $hasErrorProperty = $response.PSObject.Properties.Name -contains 'error'
        $hasSuccessProperty = $response.PSObject.Properties.Name -contains 'success'
        $reportedError = ($hasErrorProperty -and [bool]$response.error) -or
            ($hasSuccessProperty -and -not [bool]$response.success)
        if ($reportedError) {
            throw "Vast API reported an error while listing instances: $($response | ConvertTo-Json -Depth 10 -Compress)"
        }
    }
    return Find-VastInstanceInResponse -Response $response -InstanceId $InstanceId
}

function Set-DeploymentInstanceDestroyed {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $State.instance_status = 'destroyed'
    if (-not (Get-ObjectProperty -Object $State -Names @('destroyed_at'))) {
        $State.destroyed_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-DeploymentState -Config $Config -State $State | Out-Null
    return $State
}

function Test-DeploymentStateHasActiveResources {
    param([Parameter(Mandatory = $true)]$State)

    $instanceId = Get-ObjectProperty -Object $State -Names @('instance_id')
    $instanceStatus = [string](Get-ObjectProperty -Object $State -Names @('instance_status') -Default '')
    $volumeId = Get-ObjectProperty -Object $State -Names @('volume_id')
    $volumeStatus = [string](Get-ObjectProperty -Object $State -Names @('volume_status') -Default '')

    $instanceIsActive = $null -ne $instanceId -and $instanceStatus -ne 'destroyed'
    $volumeIsActive = $null -ne $volumeId -and $volumeStatus -ne 'deleted'
    return [bool]($instanceIsActive -or $volumeIsActive)
}

function Test-DeploymentStateCanResumeInstance {
    param([Parameter(Mandatory = $true)]$State)

    $instanceId = Get-ObjectProperty -Object $State -Names @('instance_id')
    $instanceStatus = [string](Get-ObjectProperty -Object $State -Names @('instance_status') -Default '')
    $volumeId = Get-ObjectProperty -Object $State -Names @('volume_id')
    $volumeStatus = [string](Get-ObjectProperty -Object $State -Names @('volume_status') -Default '')

    return [bool]($null -eq $instanceId -and
        $instanceStatus -in @('pending', 'create_failed', 'failed') -and
        $null -ne $volumeId -and
        $volumeStatus -eq 'created')
}

function Test-DeploymentStateCanContinueDeployment {
    param([Parameter(Mandatory = $true)]$State)

    $instanceId = Get-ObjectProperty -Object $State -Names @('instance_id')
    $instanceStatus = [string](Get-ObjectProperty -Object $State -Names @('instance_status') -Default '')
    $provisioned = [bool](Get-ObjectProperty -Object $State -Names @('provisioned') -Default $false)

    return [bool]($null -ne $instanceId -and
        $instanceStatus -ne 'destroyed' -and
        -not $provisioned)
}

function Format-UsdPrice {
    param(
        [Parameter(Mandatory = $true)][double]$Amount,
        [int]$Decimals = 4
    )

    $format = '0.' + ('0' * $Decimals)
    return '$' + $Amount.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-VastOfferChoiceRows {
    param([Parameter(Mandatory = $true)][object[]]$Offers)

    $rows = @()
    for ($index = 0; $index -lt $Offers.Count; $index++) {
        $offer = $Offers[$index]
        $gpuRamMb = [double](Get-ObjectProperty -Object $offer -Names @('gpu_ram') -Default 0)
        $reliability = [double](Get-ObjectProperty -Object $offer -Names @('reliability2', 'reliability') -Default 0)
        $rows += [pscustomobject]@{
            choice = $index + 1
            offer_id = Get-ObjectProperty -Object $offer -Names @('id')
            gpu_name = [string](Get-ObjectProperty -Object $offer -Names @('gpu_name') -Default 'unknown')
            gpu_ram_GB = [math]::Round($gpuRamMb / 1024, 1)
            price_USD_hour = Format-UsdPrice -Amount ([double](Get-ObjectProperty -Object $offer -Names @('dph_total', 'dph') -Default 0))
            reliability = $reliability.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)
            inet_down_Mbps = [math]::Round([double](Get-ObjectProperty -Object $offer -Names @('inet_down') -Default 0), 1)
            machine_id = Get-ObjectProperty -Object $offer -Names @('machine_id')
        }
    }
    return $rows
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
        if ($value -match "['`"]") {
            throw "Environment variable '$key' contains a quote that Vast CLI cannot parse safely."
        }
        # Keep values with spaces together for Vast CLI's parse_env(), while
        # avoiding embedded double quotes that break Windows PowerShell 5.1's
        # native argument serialization.
        $parts.Add("-e $key='$value'")
    }
    return ($parts -join ' ')
}

function Add-VastVolumeLinkArguments {
    param(
        [string[]]$Arguments = @(),
        $VolumeId,
        [Parameter(Mandatory = $true)][string]$MountPath
    )

    $result = @($Arguments)
    if ($null -ne $VolumeId -and [string]$VolumeId -ne '') {
        $result += @('--link-volume', [string]$VolumeId, '--mount-path', $MountPath)
    }
    return $result
}

function Wait-VastInstanceRunning {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId,
        [int]$TerminalStateGraceSeconds = 45
    )

    $timeout = [int]$Config.Vast.Instance.WaitTimeoutSeconds
    $poll = [int]$Config.Vast.Instance.PollIntervalSeconds
    $deadline = (Get-Date).AddSeconds($timeout)
    $retryableTerminalStates = @('stopped', 'exited', 'unknown', 'offline')
    $immediateFatalStates = @('error', 'failed')
    $terminalStateSince = $null

    while ((Get-Date) -lt $deadline) {
        $instance = Invoke-VastJson -Config $Config -Arguments @('show', 'instance', [string]$InstanceId, '--raw')
        $items = @(ConvertTo-ObjectArray -Value $instance -CandidateProperties @('instances'))
        if ($items.Count -eq 0) { throw "Instance $InstanceId was not returned by Vast." }
        $item = $items[0]
        $status = [string](Get-ObjectProperty -Object $item -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
        $intendedStatus = [string](Get-ObjectProperty -Object $item -Names @('intended_status') -Default 'unknown')
        $currentState = [string](Get-ObjectProperty -Object $item -Names @('cur_state') -Default 'unknown')
        $nextState = [string](Get-ObjectProperty -Object $item -Names @('next_state') -Default 'unknown')
        $statusMessage = [string](Get-ObjectProperty -Object $item -Names @('status_msg') -Default '')
        $statusDetails = "actual=$status, intended=$intendedStatus, current=$currentState, next=$nextState"
        if ($statusMessage) { $statusDetails += ", message=$statusMessage" }

        Write-Host "Instance $InstanceId status: $statusDetails"
        if ($status -eq 'running') { return $item }

        if ($immediateFatalStates -contains $status) {
            throw "Instance $InstanceId failed to start ($statusDetails). Run 'vastai logs $InstanceId --tail 200' for container logs."
        }
        if ($retryableTerminalStates -contains $status) {
            if ($null -eq $terminalStateSince) { $terminalStateSince = Get-Date }
            $terminalSeconds = ((Get-Date) - $terminalStateSince).TotalSeconds
            if ($terminalSeconds -ge $TerminalStateGraceSeconds) {
                throw "Instance $InstanceId did not leave '$status' within $TerminalStateGraceSeconds seconds ($statusDetails). Run 'vastai logs $InstanceId --tail 200' for container logs."
            }
        } else {
            $terminalStateSince = $null
        }
        Start-Sleep -Seconds $poll
    }
    throw "Timed out after $timeout seconds waiting for instance $InstanceId to run. Use 'vastai show instance $InstanceId --raw' and 'vastai logs $InstanceId --tail 200' for details."
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
    $items = @(ConvertTo-ObjectArray -Value $instanceResponse -CandidateProperties @('instances'))
    if ($items.Count -eq 0) { throw "Instance $InstanceId was not returned by Vast." }
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
        '-o', "ConnectTimeout=$($Config.Vast.Ssh.ConnectTimeoutSeconds)",
        '-o', 'BatchMode=yes',
        '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3'
    )
    $identity = Resolve-SshIdentityPath -Path ([string]$Config.Vast.Ssh.IdentityFile)
    if (-not $identity) {
        $environmentPath = Resolve-ProjectPath -Path 'user-config/environment.json'
        if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
            try {
                $environment = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $identity = Resolve-SshIdentityPath -Path ([string]$environment.private_key_path)
            }
            catch {
                throw "Could not read the verified SSH identity from ${environmentPath}: $($_.Exception.Message)"
            }
        }
    }
    if ($identity) {
        if (-not (Test-Path -LiteralPath $identity -PathType Leaf)) {
            throw "Configured SSH private key was not found: $identity"
        }
        $arguments += @('-i', $identity)
    }
    return $arguments
}

function Wait-VastSshReady {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$Endpoint,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 180,
        [ValidateRange(1, 60)][int]$PollIntervalSeconds = 5
    )

    Assert-CommandExists -Name 'ssh'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastResult = $null
    $sshCommon = @(Get-SshCommonArguments -Config $Config)
    $target = "$($Endpoint.User)@$($Endpoint.Host)"

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $lastResult = Invoke-NativeCommandCapture -Command 'ssh' -Arguments ($sshCommon + @(
            '-o', 'ConnectionAttempts=1',
            '-p', [string]$Endpoint.Port,
            $target,
            "printf 'SSH_READY\\n'"
        ))
        if ($lastResult.ExitCode -eq 0 -and $lastResult.Text -match 'SSH_READY') {
            Write-Host "SSH is ready at ${target}:$($Endpoint.Port) (attempt $attempt)." -ForegroundColor Green
            return
        }

        $detail = if ($lastResult.Text) { ($lastResult.Text -split "`r?`n")[-1] } else { "exit $($lastResult.ExitCode)" }
        Write-Host "SSH is not ready yet (attempt $attempt): $detail" -ForegroundColor DarkYellow
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    $lastText = if ($null -ne $lastResult) { $lastResult.Text } else { 'No SSH attempt completed.' }
    throw "Timed out after $TimeoutSeconds seconds waiting for SSH at ${target}:$($Endpoint.Port).`n$lastText"
}

function Invoke-RemoteDeploymentVerification {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$Endpoint
    )

    Assert-CommandExists -Name 'ssh'
    $remoteDirectory = [string]$Config.Local.RemoteUploadDirectory
    if ($remoteDirectory -notmatch '^/[A-Za-z0-9._/-]+$') {
        throw "RemoteUploadDirectory cannot be safely passed to the verification shell: $remoteDirectory"
    }

    $verifyScript = "$remoteDirectory/remote/verify-deployment.sh"
    $remoteConfig = "$remoteDirectory/remote-config.json"
    $remoteCommand = "if [ -f '$verifyScript' ] && [ -f '$remoteConfig' ]; then bash '$verifyScript' '$remoteConfig'; else echo 'Remote verification files are not installed. Run menu option 5 first.' >&2; exit 21; fi"
    $sshCommon = @(Get-SshCommonArguments -Config $Config)
    $result = Invoke-NativeCommandCapture -Command 'ssh' -Arguments ($sshCommon + @(
        '-p', [string]$Endpoint.Port,
        "$($Endpoint.User)@$($Endpoint.Host)",
        $remoteCommand
    ))
    $result.Output | ForEach-Object { Write-Host $_ }
    return $result
}
