[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\remote\install-local-loras.py')).Path
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-local-installer-{0}" -f [guid]::NewGuid().ToString('N'))
$loraRoot = Join-Path $temporaryRoot 'application\models\loras'
$stagingRoot = Join-Path $temporaryRoot 'staging'
$configPath = Join-Path $temporaryRoot 'remote-config.json'
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

function Get-TestSha256 {
    param([byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Save-TestManifest {
    param([byte[]]$Bytes, [string]$StagingId)
    $manifest = [ordered]@{
        anima = [ordered]@{
            local_loras = @([ordered]@{
                relative_path = 'styles/Test Style.safetensors'
                sha256 = Get-TestSha256 -Bytes $Bytes
                size_bytes = [int64]$Bytes.Length
                staging_id = $StagingId
            })
        }
    }
    Save-JsonFile -Value $manifest -Path $configPath | Out-Null
    return $manifest.anima.local_loras[0]
}

function Invoke-Installer {
    param([string[]]$Arguments, [int]$ExpectedExitCode = 0)
    $result = Invoke-NativeCommandCapture -Command 'python' -Arguments (@($helper) + $Arguments)
    if ($result.ExitCode -ne $ExpectedExitCode) {
        throw "Local LoRA installer exit code $($result.ExitCode), expected $ExpectedExitCode.`n$($result.Text)"
    }
    return $result
}

try {
    $firstBytes = [byte[]](1, 2, 3, 4, 5)
    $firstId = ('a' * 64) -join ''
    $first = Save-TestManifest -Bytes $firstBytes -StagingId $firstId
    $check = Invoke-Installer -Arguments @('check', $configPath, $loraRoot, $stagingRoot)
    if ($check.Text -notmatch "$firstId`tupload") { throw 'A missing local LoRA was not requested for upload.' }
    [IO.File]::WriteAllBytes((Join-Path $stagingRoot "$firstId.part"), $firstBytes)
    Invoke-Installer -Arguments @('verify-stage', $configPath, $loraRoot, $stagingRoot, $firstId) | Out-Null
    Invoke-Installer -Arguments @('install', $configPath, $loraRoot, $stagingRoot) | Out-Null
    $destination = Join-Path $loraRoot 'styles\Test Style.safetensors'
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $first.sha256) {
        throw 'A verified local LoRA was not installed at its nested destination.'
    }
    $check = Invoke-Installer -Arguments @('check', $configPath, $loraRoot, $stagingRoot)
    if ($check.Text -notmatch "$firstId`tinstalled") { throw 'An identical remote local LoRA was not skipped.' }

    $secondBytes = [byte[]](9, 8, 7, 6)
    $secondId = ('b' * 64) -join ''
    $second = Save-TestManifest -Bytes $secondBytes -StagingId $secondId
    $check = Invoke-Installer -Arguments @('check', $configPath, $loraRoot, $stagingRoot)
    if ($check.Text -notmatch "$secondId`tupload") { throw 'A different remote hash was not selected for replacement.' }
    [IO.File]::WriteAllBytes((Join-Path $stagingRoot "$secondId.part"), $secondBytes)
    Invoke-Installer -Arguments @('verify-stage', $configPath, $loraRoot, $stagingRoot, $secondId) | Out-Null
    Invoke-Installer -Arguments @('install', $configPath, $loraRoot, $stagingRoot) | Out-Null
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $second.sha256) {
        throw 'A project-local LoRA did not atomically replace a different remote file.'
    }

    $badBytes = [byte[]](4, 4, 4)
    $badId = ('c' * 64) -join ''
    Save-TestManifest -Bytes ([byte[]](3, 3, 3)) -StagingId $badId | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $stagingRoot "$badId.part"), $badBytes)
    $failed = Invoke-NativeCommandCapture -Command 'python' -Arguments @($helper, 'verify-stage', $configPath, $loraRoot, $stagingRoot, $badId)
    if ($failed.ExitCode -eq 0) { throw 'A corrupt staged local LoRA was accepted.' }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $second.sha256) {
        throw 'A corrupt staged upload changed the existing remote LoRA.'
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host 'Project-local LoRA staging, skip, verification, and atomic replacement passed.' -ForegroundColor Green
