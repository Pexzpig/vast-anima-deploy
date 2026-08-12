[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$nativePowerShell = (Get-Command 'powershell.exe' -ErrorAction Stop).Source
$failureScript = @'
[Console]::Error.WriteLine('{"error":true,"status_code":403,"msg":"This action requires login."}')
exit 23
'@
$failureArguments = @('-NoProfile', '-NonInteractive', '-Command', $failureScript)

$capture = Invoke-NativeCommandCapture -Command $nativePowerShell -Arguments $failureArguments
if ($capture.ExitCode -ne 23) {
    throw "Expected exit code 23, got $($capture.ExitCode)."
}

$timeoutCaught = $false
try {
    Invoke-NativeCommandCapture `
        -Command $nativePowerShell `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 5') `
        -TimeoutSeconds 1 | Out-Null
}
catch {
    $timeoutCaught = $true
    if ($_.Exception.Message -notmatch '\[NATIVE_COMMAND_TIMEOUT\]') {
        throw "A timed native command failed for the wrong reason: $($_.Exception.Message)"
    }
}
if (-not $timeoutCaught) {
    throw 'A timed native command was allowed to run past its deadline.'
}
if ($capture.Text -notmatch 'This action requires login') {
    throw "Expected captured stderr, got: $($capture.Text)"
}

$dockerEnvironment = ConvertTo-DockerEnvironmentString -Environment @{
    COMFYUI_ARGS = '--disable-auto-launch --enable-cors-header --listen 127.0.0.1 --port 18188'
    ENABLE_AUTH = 'true'
    TZ = 'Asia/Shanghai'
}
$argumentEcho = Invoke-NativeCommandCapture `
    -Command (Join-Path $PSScriptRoot 'fixtures\echo-args.cmd') `
    -Arguments @('--env', $dockerEnvironment, '--raw')
if ($argumentEcho.ExitCode -ne 0 -or
    $argumentEcho.Output.Count -ne 3 -or
    $argumentEcho.Output[0] -ne 'ARG=[--env]' -or
    $argumentEcho.Output[1] -ne "ARG=[$dockerEnvironment]" -or
    $argumentEcho.Output[2] -ne 'ARG=[--raw]') {
    throw "The Vast --env value was split into multiple native arguments:`n$($argumentEcho.Text)"
}

# Test the exact login probe shape with a deterministic Vast CLI fixture.
$fakeVastCli = Join-Path $PSScriptRoot 'fixtures\fake-vast-403.cmd'
$unauthenticatedStatus = Get-VastAuthenticationStatus -CliPath $fakeVastCli
if ($unauthenticatedStatus.Authenticated -or $unauthenticatedStatus.Reason -ne 'AuthenticationRequired') {
    throw 'A 403 login response was incorrectly treated as authenticated.'
}

$networkFailureCaught = $false
try {
    Get-VastAuthenticationStatus -CliPath (Join-Path $PSScriptRoot 'fixtures\fake-vast-network-error.cmd') | Out-Null
}
catch {
    $networkFailureCaught = $true
    if ($_.Exception.Message -notmatch 'VAST_AUTH_CHECK_FAILED') {
        throw "A non-authentication CLI failure was misclassified: $($_.Exception.Message)"
    }
}
if (-not $networkFailureCaught) {
    throw 'A non-authentication CLI failure was incorrectly accepted.'
}

$authenticatedCli = Join-Path $PSScriptRoot 'fixtures\fake-vast-authenticated.cmd'
$authenticatedStatus = Get-VastAuthenticationStatus -CliPath $authenticatedCli
if (-not $authenticatedStatus.Authenticated -or $authenticatedStatus.UserId -ne 123) {
    throw 'A valid show-user response was not recognized as authenticated.'
}

$fixturePublicKey = Join-Path $PSScriptRoot 'fixtures\fake-public-key.pub'
$expectedPublicKeyContent = (Get-Content -LiteralPath $fixturePublicKey -Raw -Encoding ASCII).Trim()
$createArguments = @(Get-VastSshKeyCreateArguments -PublicKeyPath $fixturePublicKey)
if ($createArguments.Count -ne 4 -or
    $createArguments[0] -ne 'create' -or
    $createArguments[1] -ne 'ssh-key' -or
    $createArguments[2] -ne $expectedPublicKeyContent -or
    $createArguments[2] -eq $fixturePublicKey -or
    $createArguments[3] -ne '-y') {
    throw "The SSH key create request did not contain the public-key text: $($createArguments -join ' | ')"
}
if (-not (Test-SshPublicKeyRegistered -PublicKeyPath $fixturePublicKey -AccountText $authenticatedStatus.RawText)) {
    throw 'The registered SSH public key was not detected in the Vast account response.'
}
if (Test-SshPublicKeyRegistered -PublicKeyPath $fixturePublicKey -AccountText '{"ssh_key":"ssh-ed25519 OTHERKEY"}') {
    throw 'An unrelated SSH public key was incorrectly treated as registered.'
}

$environmentFailureCaught = $false
try {
    & (Join-Path $PSScriptRoot '..\scripts\Initialize-Environment.ps1') `
        -ConfigPath (Join-Path $PSScriptRoot 'fixtures\config-fake-vast.psd1') `
        -NonInteractive
}
catch {
    $environmentFailureCaught = $true
    if ($_.FullyQualifiedErrorId -match 'NativeCommandError') {
        throw 'The environment login probe escaped as NativeCommandError.'
    }
    if ($_.Exception.Message -notmatch 'VAST_AUTH_REQUIRED') {
        throw "Expected the normal unauthenticated flow, got: $($_.Exception.Message)"
    }
}
if (-not $environmentFailureCaught) {
    throw 'The fake unauthenticated environment was not rejected.'
}

$config = @{ Vast = @{ Cli = $nativePowerShell } }
$vastFailureCaught = $false
try {
    Invoke-VastText -Config $config -Arguments $failureArguments | Out-Null
}
catch {
    $vastFailureCaught = $true
    if ($_.FullyQualifiedErrorId -match 'NativeCommandError') {
        throw 'Native stderr escaped as NativeCommandError.'
    }
    if ($_.Exception.Message -notmatch 'Vast CLI failed \(23\)') {
        throw "Expected normalized Vast CLI failure, got: $($_.Exception.Message)"
    }
}
if (-not $vastFailureCaught) {
    throw 'Invoke-VastText did not reject the nonzero exit code.'
}

$checkedFailureCaught = $false
try {
    Invoke-NativeCommandChecked -Command $nativePowerShell -Arguments $failureArguments -FailureMessage 'Expected test failure.'
}
catch {
    $checkedFailureCaught = $true
    if ($_.FullyQualifiedErrorId -match 'NativeCommandError') {
        throw 'Checked native stderr escaped as NativeCommandError.'
    }
    if ($_.Exception.Message -notmatch 'Expected test failure.*23') {
        throw "Expected checked-command failure, got: $($_.Exception.Message)"
    }
}
if (-not $checkedFailureCaught) {
    throw 'Invoke-NativeCommandChecked did not reject the nonzero exit code.'
}

Write-Host 'Native command stderr/exit-code handling passed.' -ForegroundColor Green
