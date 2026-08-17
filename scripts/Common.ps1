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
    param([string]$ConfigPath = (Join-Path $script:ProjectRoot 'user-config\deployment.json'))

    $resolvedPath = Resolve-ProjectPath -Path $ConfigPath
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "Configuration not found: $resolvedPath. Run Start-VastAnima.ps1 to initialize it."
    }

    if ([System.IO.Path]::GetExtension($resolvedPath) -ieq '.json') {
        $json = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ConvertTo-HashtableDeep -InputObject $json
    }

    return Import-PowerShellDataFile -LiteralPath $resolvedPath
}

function Set-DeploymentSearchPreferences {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][int]$SearchLimit,
        [Parameter(Mandatory = $true)][double]$MaxHourlyUsd,
        [Parameter(Mandatory = $true)][bool]$VolumeEnabled,
        [Parameter(Mandatory = $true)][int]$VolumeSizeGb,
        [Parameter(Mandatory = $true)][ValidateSet('comfyui', 'webui')][string]$ApplicationType
    )

    $Config.Vast.Search.Query = $Query
    $Config.Vast.Search.Limit = $SearchLimit
    $Config.Vast.Search.MaxHourlyUsd = $MaxHourlyUsd
    $Config.Vast.Volume.Enabled = $VolumeEnabled
    $Config.Vast.Volume.SizeGb = $VolumeSizeGb
    $Config.Application.DefaultType = $ApplicationType
    return $Config
}

function Add-CurrentFeatureConfigurationDefaults {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Template
    )

    # These are forward additions to the current single configuration schema.
    # No obsolete selection files are read, and existing values always win.
    foreach ($field in @('ReadyTimeoutSeconds', 'ReadyPollIntervalSeconds')) {
        if (-not $Config.Vast.Ssh.ContainsKey($field)) {
            $Config.Vast.Ssh[$field] = ConvertTo-HashtableDeep -InputObject $Template.Vast.Ssh[$field]
        }
    }
    foreach ($field in @(
        'TorchVersion', 'TorchvisionVersion', 'TorchaudioVersion', 'TorchCudaVersion', 'TorchIndexUrl'
    )) {
        if (-not $Config.ComfyUI.ContainsKey($field)) {
            $Config.ComfyUI[$field] = ConvertTo-HashtableDeep -InputObject $Template.ComfyUI[$field]
        }
    }
    foreach ($field in @(
        'Commit', 'TorchVersion', 'TorchvisionVersion', 'TorchCudaVersion', 'TorchIndexUrl',
        'Localization', 'Extensions'
    )) {
        if (-not $Config.WebUI.ContainsKey($field)) {
            $Config.WebUI[$field] = ConvertTo-HashtableDeep -InputObject $Template.WebUI[$field]
        }
    }
    if (-not $Config.Anima.ContainsKey('WorkflowSha256')) {
        $oldDefaultWorkflowUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_anima_base_v1.json'
        if ([string]$Config.Anima.WorkflowUrl -eq $oldDefaultWorkflowUrl -or
            [string]$Config.Anima.WorkflowUrl -eq [string]$Template.Anima.WorkflowUrl) {
            $Config.Anima.WorkflowUrl = [string]$Template.Anima.WorkflowUrl
            $Config.Anima.WorkflowSha256 = [string]$Template.Anima.WorkflowSha256
        } else {
            # A custom workflow URL needs its own matching digest; do not attach
            # the template digest to unrelated content.
            $Config.Anima.WorkflowSha256 = ''
        }
    }
    if (-not $Config.Anima.ContainsKey('ManagedWorkflowFileName')) {
        $Config.Anima.ManagedWorkflowFileName = [string]$Template.Anima.ManagedWorkflowFileName
    }
    foreach ($field in @('HiresWorkflowFileName', 'ManagedLoRAs', 'ManualLoRASlots')) {
        if (-not $Config.Anima.ContainsKey($field)) {
            $Config.Anima[$field] = ConvertTo-HashtableDeep -InputObject $Template.Anima[$field]
        }
    }
    foreach ($group in @('Turbo', 'Hires')) {
        if (-not $Config.Anima.ContainsKey($group)) {
            $Config.Anima[$group] = ConvertTo-HashtableDeep -InputObject $Template.Anima[$group]
            continue
        }
        foreach ($field in $Template.Anima[$group].Keys) {
            if (-not $Config.Anima[$group].ContainsKey($field)) {
                $Config.Anima[$group][$field] = ConvertTo-HashtableDeep -InputObject $Template.Anima[$group][$field]
            }
        }
    }
    if (-not $Config.Secrets.ContainsKey('CivitaiTokenEnvironmentVariable')) {
        $Config.Secrets.CivitaiTokenEnvironmentVariable = [string]$Template.Secrets.CivitaiTokenEnvironmentVariable
    }
    foreach ($lora in @($Config.Anima.ManagedLoRAs)) {
        if (-not $lora.ContainsKey('Source')) {
            $lora.Source = if ([string]$lora.Url -match '^https://(?:www\.)?civitai\.com/') { 'civitai' } else { 'direct' }
        }
        if (-not $lora.ContainsKey('SourcePageUrl')) {
            $lora.SourcePageUrl = if ([string]$lora.Source -eq 'civitai') { [string]$lora.Url } else { '' }
        }
        if (-not $lora.ContainsKey('ModelId')) { $lora.ModelId = $null }
        if (-not $lora.ContainsKey('ModelVersionId')) {
            $lora.ModelVersionId = if ([string]$lora.Url -match '/api/download/models/(\d+)') { [int64]$Matches[1] } else { $null }
        }
        if (-not $lora.ContainsKey('BaseModel')) { $lora.BaseModel = 'Anima' }
        if (-not $lora.ContainsKey('TriggerWords')) { $lora.TriggerWords = @() }
        if (-not $lora.ContainsKey('AutoApplyInComfyUI')) { $lora.AutoApplyInComfyUI = $true }
    }
    return $Config
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
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0,
        [switch]$Quiet
    )

    $lastResult = $null
    $lastTimeoutMessage = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $lastResult = Invoke-NativeCommandCapture `
                -Command $Command `
                -Arguments $Arguments `
                -TimeoutSeconds $TimeoutSeconds
            $lastTimeoutMessage = $null
        }
        catch {
            if ($_.Exception.Message -notmatch '\[NATIVE_COMMAND_TIMEOUT\]') { throw }
            $lastResult = $null
            $lastTimeoutMessage = $_.Exception.Message
            if ($attempt -lt $Attempts) {
                Write-Warning "$Command timed out (attempt $attempt/$Attempts). Retrying in $DelaySeconds seconds..."
                if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
                continue
            }
            break
        }
        if (-not $Quiet) {
            $lastResult.Output | ForEach-Object { Write-Host $_ }
        }
        if ($lastResult.ExitCode -eq 0) { return }

        if ($attempt -lt $Attempts) {
            Write-Warning "$Command failed with exit code $($lastResult.ExitCode) (attempt $attempt/$Attempts). Retrying in $DelaySeconds seconds..."
            if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        }
    }

    if ($lastTimeoutMessage) {
        throw "$FailureMessage Native command timed out after $Attempts attempts.`n$lastTimeoutMessage"
    }
    throw "$FailureMessage Native command failed after $Attempts attempts with exit code $($lastResult.ExitCode).`n$($lastResult.Text)"
}

function Write-TransientStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Complete,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::DarkCyan
    )

    $outputRedirected = $true
    try { $outputRedirected = [Console]::IsOutputRedirected } catch {}
    if ($outputRedirected) {
        if ($Complete) { Write-Host $Message -ForegroundColor $ForegroundColor }
        return
    }

    $width = 120
    try { $width = [Math]::Max(40, [Console]::BufferWidth - 1) } catch {}
    $display = if ($Message.Length -ge $width) { $Message.Substring(0, $width - 1) } else { $Message }
    Write-Host ("`r{0,-$width}" -f $display) -NoNewline -ForegroundColor $ForegroundColor
    if ($Complete) { Write-Host '' }
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
        $hasValue = $false
        $value = $null
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            $hasValue = $true
            $value = $Object[$name]
        } elseif ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
            $hasValue = $true
            $value = $Object.$name
        }
        if ($hasValue) {
            if ($null -ne $value -and [string]$value -ne '') { return $value }
        }
    }
    return $Default
}

function Get-VastAccountInstances {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30
    )

    $response = Invoke-VastJson -Config $Config -Arguments @('show', 'instances', '--raw') -TimeoutSeconds $TimeoutSeconds
    if ($null -ne $response) {
        $reportedError = (($response.PSObject.Properties.Name -contains 'error') -and [bool]$response.error) -or
            (($response.PSObject.Properties.Name -contains 'success') -and -not [bool]$response.success)
        if ($reportedError) {
            throw "Vast API reported an error while listing instances: $($response | ConvertTo-Json -Depth 10 -Compress)"
        }
    }
    return @(ConvertTo-ObjectArray -Value $response -CandidateProperties @('instances'))
}

function ConvertTo-VastInstanceChoiceRows {
    param([Parameter(Mandatory = $true)][object[]]$Instances)

    $rows = @()
    for ($index = 0; $index -lt $Instances.Count; $index++) {
        $instance = $Instances[$index]
        $price = Get-ObjectProperty -Object $instance -Names @('dph_total', 'dph')
        $rows += [pscustomobject]@{
            choice = $index + 1
            status = [string](Get-ObjectProperty -Object $instance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
            label = [string](Get-ObjectProperty -Object $instance -Names @('label') -Default 'unknown')
            gpu = [string](Get-ObjectProperty -Object $instance -Names @('gpu_name', 'gpu') -Default 'unknown')
            image = [string](Get-ObjectProperty -Object $instance -Names @('image_uuid', 'image', 'image_name') -Default 'unknown')
            region = [string](Get-ObjectProperty -Object $instance -Names @('geolocation', 'location') -Default 'unknown')
            ip = [string](Get-ObjectProperty -Object $instance -Names @('public_ipaddr', 'public_ip', 'ssh_host') -Default 'unknown')
            price_USD_hour = if ($null -eq $price) { 'unknown' } else { Format-UsdPrice -Amount ([double]$price) }
        }
    }
    return $rows
}

function Assert-AttachedInstanceState {
    param([Parameter(Mandatory = $true)]$State)

    $required = @(
        'schema_version', 'source', 'instance_id', 'label', 'application_type',
        'deployment_image', 'service_name', 'listen_host', 'remote_port', 'local_port',
        'application_root', 'ssh_host', 'ssh_port', 'verified_at'
    )
    $missing = @($required | Where-Object { -not (Test-ObjectProperty -Object $State -Name $_) })
    if ($missing.Count -gt 0) { throw "Attached instance state is missing required field(s): $($missing -join ', ')." }
    if ([int]$State.schema_version -ne 1 -or [string]$State.source -ne 'external_script_instance') {
        throw 'Attached instance state has an unsupported schema or source.'
    }
    if ([string]$State.application_type -notin @('comfyui', 'webui')) { throw 'Attached instance state has an unsupported application type.' }
    if ([int]$State.remote_port -lt 1 -or [int]$State.remote_port -gt 65535 -or
        [int]$State.local_port -lt 1 -or [int]$State.local_port -gt 65535) {
        throw 'Attached instance state contains an invalid application port.'
    }
    return $State
}

function Get-AttachedInstanceState {
    $path = Resolve-ProjectPath -Path 'state/attached-instance.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return Assert-AttachedInstanceState -State $state
    } catch {
        throw "Attached instance state is invalid: $path. $($_.Exception.Message)"
    }
}

function Save-AttachedInstanceState {
    param([Parameter(Mandatory = $true)]$State)

    Assert-AttachedInstanceState -State $State | Out-Null
    return Save-JsonFile -Value $State -Path 'state/attached-instance.json'
}

function Get-DeploymentApplication {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        $State
    )

    $type = if ($null -eq $State) {
        [string]$Config.Application.DefaultType
    } else {
        if (-not (Test-ObjectProperty -Object $State -Name 'application_type') -or
            [string]::IsNullOrWhiteSpace([string]$State.application_type)) {
            throw 'Deployment state is missing required field: application_type.'
        }
        [string]$State.application_type
    }
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

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $Object.PSObject.Properties.Name -contains $Name
}

function Assert-DeploymentState {
    param([Parameter(Mandatory = $true)]$State)

    $requiredFields = @(
        'schema_version', 'created_at', 'updated_at', 'search_query',
        'offer_id', 'machine_id', 'gpu_name', 'hourly_usd',
        'volume_monthly_usd', 'estimated_total_hourly_usd',
        'volume_id', 'volume_label', 'volume_status', 'storage_mode',
        'application_type', 'deployment_image', 'instance_id', 'instance_status',
        'provisioned', 'provisioned_at', 'ssh_host', 'ssh_port', 'last_error',
        'destroyed_at', 'volume_deleted_at'
    )
    $missingFields = @($requiredFields | Where-Object { -not (Test-ObjectProperty -Object $State -Name $_) })
    if ($missingFields.Count -gt 0) {
        throw "Deployment state is incompatible with the current schema; missing required field(s): $($missingFields -join ', ')."
    }
    if ([int]$State.schema_version -ne 2) {
        throw "Unsupported deployment state schema_version '$($State.schema_version)'; expected 2."
    }
    if ([string]$State.application_type -notin @('comfyui', 'webui')) {
        throw "Unsupported deployment state application_type '$($State.application_type)'."
    }
    if ([string]$State.storage_mode -notin @('volume', 'instance_disk')) {
        throw "Unsupported deployment state storage_mode '$($State.storage_mode)'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$State.deployment_image)) {
        throw 'Deployment state deployment_image must not be empty.'
    }
    if ([string]$State.storage_mode -eq 'instance_disk' -and
        ($null -ne $State.volume_id -or [string]$State.volume_status -ne 'disabled')) {
        throw 'Instance-disk deployment state must not track a persistent volume.'
    }
    return $State
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

function Sync-DeploymentInstanceState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AccountInstances
    )

    $instanceId = Get-ObjectProperty -Object $State -Names @('instance_id')
    $previousStatus = [string](Get-ObjectProperty -Object $State -Names @('instance_status') -Default '')
    if ($null -eq $instanceId -or $previousStatus -eq 'destroyed') {
        return [pscustomobject]@{
            InstanceId = $instanceId
            PreviousStatus = $previousStatus
            CurrentStatus = $previousStatus
            Saved = $false
            Found = $false
        }
    }

    $liveInstance = Find-VastInstanceInResponse -Response $AccountInstances -InstanceId ([int64]$instanceId)
    if ($null -eq $liveInstance) {
        $currentStatus = 'destroyed'
        $State.instance_status = $currentStatus
        if (-not (Get-ObjectProperty -Object $State -Names @('destroyed_at'))) {
            $State.destroyed_at = (Get-Date).ToUniversalTime().ToString('o')
        }
    } else {
        $currentStatus = [string](Get-ObjectProperty -Object $liveInstance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
        if ([string]::IsNullOrWhiteSpace($currentStatus) -or $currentStatus -eq 'unknown') {
            $currentStatus = $previousStatus
        } else {
            $State.instance_status = $currentStatus
        }
    }

    # Persist exactly once for this startup reconciliation, even when the
    # reported status is unchanged, so updated_at records the account check.
    Save-DeploymentState -Config $Config -State $State | Out-Null
    return [pscustomobject]@{
        InstanceId = [int64]$instanceId
        PreviousStatus = $previousStatus
        CurrentStatus = $currentStatus
        Saved = $true
        Found = ($null -ne $liveInstance)
    }
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
            gpu_name = [string](Get-ObjectProperty -Object $offer -Names @('gpu_name') -Default 'unknown')
            gpu_ram_GB = [math]::Round($gpuRamMb / 1024, 1)
            price_USD_hour = Format-UsdPrice -Amount ([double](Get-ObjectProperty -Object $offer -Names @('dph_total', 'dph') -Default 0))
            reliability = $reliability.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)
            inet_down_Mbps = [math]::Round([double](Get-ObjectProperty -Object $offer -Names @('inet_down') -Default 0), 1)
            ip = [string](Get-ObjectProperty -Object $offer -Names @('public_ipaddr', 'public_ip', 'ssh_host') -Default 'unknown')
            region = [string](Get-ObjectProperty -Object $offer -Names @('geolocation', 'location') -Default 'unknown')
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
    $json = $Value | ConvertTo-Json -Depth 20
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolved, $json + [Environment]::NewLine, $utf8WithoutBom)
    return $resolved
}

function Get-DeploymentState {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $path = Resolve-ProjectPath -Path ([string]$Config.Local.StatePath)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Deployment state not found: $path. Run New-VastDeployment.ps1 first."
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Deployment state is not valid JSON: $path. $($_.Exception.Message)"
    }
    return Assert-DeploymentState -State $state
}

function Save-DeploymentState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    Assert-DeploymentState -State $State | Out-Null
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

        if ($status -eq 'running') {
            Write-TransientStatus -Message "Instance $InstanceId is running." -Complete -ForegroundColor Green
            return $item
        }
        $elapsedSeconds = [Math]::Max(0, [int]($timeout - ($deadline - (Get-Date)).TotalSeconds))
        Write-TransientStatus -Message "Waiting for instance $InstanceId ($status, ${elapsedSeconds}s elapsed)..."

        if ($immediateFatalStates -contains $status) {
            Write-TransientStatus -Message "Instance $InstanceId failed to start." -Complete -ForegroundColor Red
            throw "Instance $InstanceId failed to start ($statusDetails). Run 'vastai logs $InstanceId --tail 200' for container logs."
        }
        if ($retryableTerminalStates -contains $status) {
            if ($null -eq $terminalStateSince) { $terminalStateSince = Get-Date }
            $terminalSeconds = ((Get-Date) - $terminalStateSince).TotalSeconds
            if ($terminalSeconds -ge $TerminalStateGraceSeconds) {
                Write-TransientStatus -Message "Instance $InstanceId remained in '$status'." -Complete -ForegroundColor Red
                throw "Instance $InstanceId did not leave '$status' within $TerminalStateGraceSeconds seconds ($statusDetails). Run 'vastai logs $InstanceId --tail 200' for container logs."
            }
        } else {
            $terminalStateSince = $null
        }
        Start-Sleep -Seconds $poll
    }
    Write-TransientStatus -Message "Timed out waiting for instance $InstanceId." -Complete -ForegroundColor Red
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

function Get-VastSshEndpointCandidatesFromInstance {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId,
        [Parameter(Mandatory = $true)]$Instance,
        [switch]$AllowUnavailable,
        [switch]$SkipCliFallback,
        [ValidateRange(1, 30)][int]$CliTimeoutSeconds = 30
    )

    $directHost = Get-ObjectProperty -Object $Instance -Names @('public_ipaddr', 'public_ip')
    $directPort = $null
    if (Test-ObjectProperty -Object $Instance -Name 'ports') {
        $ports = if ($Instance -is [System.Collections.IDictionary]) { $Instance['ports'] } else { $Instance.ports }
        foreach ($key in @('22/tcp', '22')) {
            if ($null -ne $ports -and (Test-ObjectProperty -Object $ports -Name $key)) {
                $mapping = if ($ports -is [System.Collections.IDictionary]) { $ports[$key] } else { $ports.$key }
                foreach ($mappingItem in @($mapping)) {
                    $directPort = Get-ObjectProperty -Object $mappingItem -Names @('HostPort', 'host_port')
                    if ($null -ne $directPort) { break }
                }
                break
            }
        }
    }
    $proxyHost = Get-ObjectProperty -Object $Instance -Names @('ssh_host')
    $proxyPort = Get-ObjectProperty -Object $Instance -Names @('ssh_port')

    $instanceConfig = Get-ObjectProperty -Object $Config.Vast -Names @('Instance')
    $preferDirect = [bool](Get-ObjectProperty -Object $instanceConfig -Names @('DirectSsh') -Default $false)
    $candidateSpecs = if ($preferDirect) {
        @(
            @{ Type = 'direct'; Host = $directHost; Port = $directPort },
            @{ Type = 'proxy'; Host = $proxyHost; Port = $proxyPort }
        )
    } else {
        @(
            @{ Type = 'proxy'; Host = $proxyHost; Port = $proxyPort },
            @{ Type = 'direct'; Host = $directHost; Port = $directPort }
        )
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $candidateKeys = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in $candidateSpecs) {
        $hostName = [string]$spec.Host
        $port = if ($null -eq $spec.Port) { 0 } else { [int]$spec.Port }
        if ([string]::IsNullOrWhiteSpace($hostName) -or $port -lt 1 -or $port -gt 65535) { continue }
        $candidateKey = "${hostName}:$port"
        if (-not $candidateKeys.Add($candidateKey)) { continue }
        $candidates.Add([pscustomobject]@{
            User = [string]$Config.Vast.Ssh.User
            Host = $hostName
            Port = $port
            ConnectionType = [string]$spec.Type
        })
    }

    $hasProxyCandidate = @($candidates | Where-Object { $_.ConnectionType -eq 'proxy' }).Count -gt 0
    if (-not $hasProxyCandidate -and -not $SkipCliFallback) {
        try {
            $url = Invoke-VastText -Config $Config -Arguments @('ssh-url', [string]$InstanceId) -TimeoutSeconds $CliTimeoutSeconds
            if ($url -match 'ssh://(?:(?<user>[^@/]+)@)?(?<host>[^:/\s]+):(?<port>\d+)') {
                $hostName = $Matches.host
                $port = [int]$Matches.port
                $candidateKey = "${hostName}:$port"
                if ($candidateKeys.Add($candidateKey)) {
                    $cliCandidate = [pscustomobject]@{
                        User = [string]$Config.Vast.Ssh.User
                        Host = [string]$hostName
                        Port = $port
                        ConnectionType = 'cli'
                    }
                    if ($preferDirect) { $candidates.Add($cliCandidate) } else { $candidates.Insert(0, $cliCandidate) }
                }
            }
        } catch {
            if (-not $AllowUnavailable) { throw }
        }
    }

    if ($candidates.Count -eq 0) {
        if ($AllowUnavailable) { return @() }
        throw "Could not resolve SSH endpoint for instance $InstanceId."
    }

    return $candidates.ToArray()
}

function Resolve-VastSshEndpointFromInstance {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId,
        [Parameter(Mandatory = $true)]$Instance,
        [switch]$AllowUnavailable,
        [switch]$SkipCliFallback,
        [ValidateRange(1, 30)][int]$CliTimeoutSeconds = 30
    )

    $candidates = @(Get-VastSshEndpointCandidatesFromInstance `
        -Config $Config `
        -InstanceId $InstanceId `
        -Instance $Instance `
        -AllowUnavailable:$AllowUnavailable `
        -SkipCliFallback:$SkipCliFallback `
        -CliTimeoutSeconds $CliTimeoutSeconds)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Get-VastSshEndpoint {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int64]$InstanceId
    )

    $instanceResponse = Invoke-VastJson -Config $Config -Arguments @('show', 'instance', [string]$InstanceId, '--raw')
    $items = @(ConvertTo-ObjectArray -Value $instanceResponse -CandidateProperties @('instances'))
    if ($items.Count -eq 0) { throw "Instance $InstanceId was not returned by Vast." }
    return Resolve-VastSshEndpointFromInstance -Config $Config -InstanceId $InstanceId -Instance $items[0]
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
        [Parameter(Mandatory = $true)][int64]$InstanceId,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0,
        [ValidateRange(0, 60)][int]$PollIntervalSeconds = 0,
        [ValidateRange(0, 300)][int]$TerminalStateGraceSeconds = 45
    )

    Assert-CommandExists -Name 'ssh'
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = [int]$Config.Vast.Ssh.ReadyTimeoutSeconds }
    if ($PollIntervalSeconds -le 0) { $PollIntervalSeconds = [int]$Config.Vast.Ssh.ReadyPollIntervalSeconds }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $sshCommon = @(Get-SshCommonArguments -Config $Config) + @('-o', 'LogLevel=QUIET')
    $startedAt = Get-Date
    $lastEndpoints = @()
    $lastStatus = 'unavailable'
    $lastStatusDetails = 'Vast status has not been returned yet.'
    $lastStatusError = $null
    $lastSshSummary = 'SSH has not been attempted yet.'
    $terminalStateSince = $null
    $immediateFatalStates = @('error', 'failed')
    $graceTerminalStates = @('exited', 'stopped', 'offline', 'unknown', 'frozen')

    while ((Get-Date) -lt $deadline) {
        $statusAvailable = $false
        $statusMessage = ''
        try {
            $statusQueryTimeoutSeconds = [Math]::Max(1, [Math]::Min(30, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)))
            $instanceResponse = Invoke-VastJson `
                -Config $Config `
                -Arguments @('show', 'instance', [string]$InstanceId, '--raw') `
                -TimeoutSeconds $statusQueryTimeoutSeconds
            $items = @(ConvertTo-ObjectArray -Value $instanceResponse -CandidateProperties @('instances'))
            if ($items.Count -eq 0) { throw "Instance $InstanceId was not returned by Vast." }
            $instance = $items[0]
            if (Test-ObjectProperty -Object $instance -Name 'actual_status') {
                $rawStatus = if ($instance -is [System.Collections.IDictionary]) { $instance['actual_status'] } else { $instance.actual_status }
                $lastStatus = if ($null -eq $rawStatus -or [string]::IsNullOrWhiteSpace([string]$rawStatus)) { 'provisioning' } else { ([string]$rawStatus).Trim().ToLowerInvariant() }
            } else {
                $lastStatus = ([string](Get-ObjectProperty -Object $instance -Names @('status', 'cur_state') -Default 'unknown')).Trim().ToLowerInvariant()
            }
            $intendedStatus = [string](Get-ObjectProperty -Object $instance -Names @('intended_status') -Default 'unknown')
            $currentState = [string](Get-ObjectProperty -Object $instance -Names @('cur_state') -Default 'unknown')
            $nextState = [string](Get-ObjectProperty -Object $instance -Names @('next_state') -Default 'unknown')
            $statusMessage = (([string](Get-ObjectProperty -Object $instance -Names @('status_msg') -Default '')) -replace '\s+', ' ').Trim()
            if ($statusMessage.Length -gt 300) { $statusMessage = $statusMessage.Substring(0, 297) + '...' }
            $lastStatusDetails = "actual=$lastStatus, intended=$intendedStatus, current=$currentState, next=$nextState"
            if ($statusMessage) { $lastStatusDetails += ", message=$statusMessage" }
            $endpointQueryTimeoutSeconds = [Math]::Max(1, [Math]::Min(30, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)))
            $resolvedEndpoints = @(Get-VastSshEndpointCandidatesFromInstance `
                -Config $Config `
                -InstanceId $InstanceId `
                -Instance $instance `
                -AllowUnavailable `
                -SkipCliFallback:($lastStatus -ne 'running') `
                -CliTimeoutSeconds $endpointQueryTimeoutSeconds)
            if ($resolvedEndpoints.Count -gt 0) { $lastEndpoints = $resolvedEndpoints }
            $lastStatusError = $null
            $statusAvailable = $true
        } catch {
            $lastStatusError = (($_.Exception.Message -replace '\s+', ' ').Trim())
            if ($lastStatusError.Length -gt 500) { $lastStatusError = $lastStatusError.Substring(0, 497) + '...' }
            $lastStatus = 'unavailable'
        }

        $elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
        $endpointText = if ($lastEndpoints.Count -eq 0) {
            'pending'
        } else {
            @($lastEndpoints | ForEach-Object { "$($_.ConnectionType)=$($_.Host):$($_.Port)" }) -join ' -> '
        }
        $statusSuffix = ''
        if ($statusMessage) {
            $statusMessageDisplay = ($statusMessage -replace '\s+', ' ').Trim()
            if ($statusMessageDisplay.Length -gt 70) { $statusMessageDisplay = $statusMessageDisplay.Substring(0, 67) + '...' }
            $statusSuffix = ", message=$statusMessageDisplay"
        } elseif ($lastStatusError) {
            $statusSuffix = ', status query unavailable'
        }
        Write-TransientStatus `
            -Message "Waiting for SSH: Vast=$lastStatus, endpoint=$endpointText, elapsed=${elapsedSeconds}/${TimeoutSeconds}s$statusSuffix" `
            -ForegroundColor DarkYellow

        if ($statusAvailable) {
            if ($immediateFatalStates -contains $lastStatus) {
                Write-TransientStatus -Message "Instance $InstanceId failed while waiting for SSH." -Complete -ForegroundColor Red
                throw "Instance $InstanceId cannot become SSH-ready ($lastStatusDetails). Run 'vastai show instance $InstanceId --raw' and 'vastai logs $InstanceId --tail 200' for details."
            }
            if ($graceTerminalStates -contains $lastStatus) {
                if ($null -eq $terminalStateSince) { $terminalStateSince = Get-Date }
                if (((Get-Date) - $terminalStateSince).TotalSeconds -ge $TerminalStateGraceSeconds) {
                    Write-TransientStatus -Message "Instance $InstanceId remained in '$lastStatus' while waiting for SSH." -Complete -ForegroundColor Red
                    throw "Instance $InstanceId remained in '$lastStatus' for $TerminalStateGraceSeconds seconds while waiting for SSH ($lastStatusDetails). Run 'vastai show instance $InstanceId --raw' and 'vastai logs $InstanceId --tail 200' for details."
                }
            } else {
                $terminalStateSince = $null
            }
        }

        $shouldProbeSsh = $lastEndpoints.Count -gt 0 -and (($statusAvailable -and $lastStatus -eq 'running') -or -not $statusAvailable)
        if ($shouldProbeSsh) {
            $roundFailures = @()
            foreach ($endpoint in $lastEndpoints) {
                $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
                if ($remainingSeconds -le 0) { break }
                $target = "$($endpoint.User)@$($endpoint.Host)"
                $probeTimeoutSeconds = [Math]::Min($remainingSeconds, [Math]::Max(5, [int]$Config.Vast.Ssh.ConnectTimeoutSeconds + 10))
                try {
                    $lastResult = Invoke-NativeCommandCapture -Command 'ssh' -Arguments ($sshCommon + @(
                        '-T', '-n',
                        '-o', 'ConnectionAttempts=1',
                        '-p', [string]$endpoint.Port,
                        $target,
                        "printf 'SSH_READY\\n'"
                    )) -TimeoutSeconds $probeTimeoutSeconds
                    if ($lastResult.ExitCode -eq 0 -and $lastResult.Text -match 'SSH_READY') {
                        $elapsedSeconds = [int]((Get-Date) - $startedAt).TotalSeconds
                        Write-TransientStatus -Message "SSH is ready via $($endpoint.ConnectionType) at ${target}:$($endpoint.Port) after ${elapsedSeconds}s." -Complete -ForegroundColor Green
                        return $endpoint
                    }
                    $failureLines = @($lastResult.Text -split "`r?`n" | Where-Object {
                        $_ -and $_ -notmatch '^(Welcome to vast\.ai\.|Have fun!|AI agents:)'
                    })
                    $failureSummary = if ($failureLines.Count -gt 0) { [string]$failureLines[-1] } else { "SSH probe exited with code $($lastResult.ExitCode)." }
                } catch {
                    $failureSummary = (($_.Exception.Message -replace '\s+', ' ').Trim())
                    if ($failureSummary.Length -gt 500) { $failureSummary = $failureSummary.Substring(0, 497) + '...' }
                }
                $roundFailures += "$($endpoint.ConnectionType) $($endpoint.Host):$($endpoint.Port): $failureSummary"
            }
            if ($roundFailures.Count -gt 0) {
                $lastSshSummary = $roundFailures -join '; '
                if ($lastSshSummary.Length -gt 800) { $lastSshSummary = $lastSshSummary.Substring(0, 797) + '...' }
            }
        }

        $remainingForSleep = [int][Math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($remainingForSleep -gt 0) {
            Start-Sleep -Seconds ([Math]::Min($PollIntervalSeconds, $remainingForSleep))
        }
    }

    $statusErrorSuffix = if ($lastStatusError) { " Last Vast query error: $lastStatusError" } else { '' }
    Write-TransientStatus -Message "Timed out waiting for SSH for instance $InstanceId." -Complete -ForegroundColor Red
    throw "Timed out after $TimeoutSeconds seconds waiting for SSH for instance $InstanceId. Last Vast state: $lastStatusDetails.$statusErrorSuffix Last SSH result: $lastSshSummary. Run 'vastai show instance $InstanceId --raw' and 'vastai logs $InstanceId --tail 200' for details."
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
