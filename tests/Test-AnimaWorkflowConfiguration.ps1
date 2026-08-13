[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validator = Join-Path $projectRoot 'scripts\Test-Configuration.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-workflow-config-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

function Test-ConfigurationRejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Mutation,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $candidate = Get-DeployConfig -ConfigPath 'config.psd1'
    & $Mutation $candidate
    $candidatePath = Join-Path $temporaryRoot ("{0}.json" -f [guid]::NewGuid().ToString('N'))
    Save-JsonFile -Value $candidate -Path $candidatePath | Out-Null
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $candidatePath *> $null
    $validatorExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($validatorExitCode -eq 0) { throw "Invalid Anima configuration was accepted: $Description" }
}

try {
    $valid = Get-DeployConfig -ConfigPath 'config.psd1'
    $valid.Anima.ManagedLoRAs = @(@{
        Name = 'valid-character.safetensors'
        Kind = 'character'
        Url = 'https://example.invalid/valid-character.safetensors'
        Sha256 = ('a' * 64) -join ''
        Strength = 0.75
        Enabled = $true
    })
    $validPath = Join-Path $temporaryRoot 'valid.json'
    Save-JsonFile -Value $valid -Path $validPath | Out-Null
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $validPath *> $null
    $validatorExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($validatorExitCode -ne 0) { throw 'A valid managed Anima LoRA configuration was rejected.' }

    Test-ConfigurationRejected { param($c) $c.Anima.Hires.Scale = 2.1 } 'hires scale above 2.0'
    Test-ConfigurationRejected { param($c) $c.Anima.Hires.Denoise = 0 } 'zero hires denoise'
    Test-ConfigurationRejected { param($c) $c.Anima.Hires.UpscaleMethod = 'unknown' } 'unsupported latent upscale method'
    Test-ConfigurationRejected { param($c) $c.Anima.Turbo.Sha256 = 'bad' } 'invalid Turbo SHA-256'
    Test-ConfigurationRejected { param($c) $c.Anima.Turbo.EnabledByDefault = 'false' } 'non-Boolean Turbo default flag'
    Test-ConfigurationRejected { param($c) $c.Anima.ManualLoRASlots = 1 } 'missing style manual slot'
    Test-ConfigurationRejected {
        param($c)
        $c.Anima.ManagedLoRAs = @(@{
            Name = '../unsafe.safetensors'; Kind = 'other'; Url = 'http://example.invalid/lora'
            Sha256 = 'bad'; Strength = 2.1; Enabled = $true
        })
    } 'unsafe managed LoRA fields'
    Test-ConfigurationRejected {
        param($c)
        $entry = @{ Name = 'duplicate.safetensors'; Kind = 'style'; Url = 'https://example.invalid/lora'; Sha256 = ('b' * 64) -join ''; Strength = 1.0; Enabled = $true }
        $c.Anima.ManagedLoRAs = @($entry, $entry.Clone())
    } 'duplicate managed LoRA names'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

Write-Host 'Anima Turbo, LoRA, and hires configuration validation passed.' -ForegroundColor Green
