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
if ($capture.Text -notmatch 'This action requires login') {
    throw "Expected captured stderr, got: $($capture.Text)"
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
