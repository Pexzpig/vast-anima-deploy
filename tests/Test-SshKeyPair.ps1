[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testDirectory = Join-Path $temporaryRoot ("vast-anima-ssh-test-{0}" -f [guid]::NewGuid().ToString('N'))
$privateKeyPath = Join-Path $testDirectory 'id_ed25519'
$publicKeyPath = "$privateKeyPath.pub"

try {
    New-Item -ItemType Directory -Path $testDirectory | Out-Null
    $keygen = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @(
        '-q', '-t', 'ed25519', '-f', $privateKeyPath, '-N', '""', '-C', 'vast-anima-test'
    )
    if ($keygen.ExitCode -ne 0) { throw "Test key generation failed: $($keygen.Text)" }
    if (-not (Test-SshKeyPairUsable -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath)) {
        throw 'A matching unencrypted SSH key pair was rejected.'
    }
    if (Test-SshKeyPairUsable -PrivateKeyPath $privateKeyPath -PublicKeyPath (Join-Path $testDirectory 'missing.pub')) {
        throw 'A key pair with a missing public key was accepted.'
    }
}
finally {
    foreach ($path in @($privateKeyPath, $publicKeyPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ((Test-Path -LiteralPath $testDirectory) -and
        ([System.IO.Path]::GetFullPath($testDirectory).StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
        Remove-Item -LiteralPath $testDirectory -Force
    }
}

Write-Host 'SSH private/public key-pair validation passed.' -ForegroundColor Green
