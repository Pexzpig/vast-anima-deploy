[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot '..\scripts\LoRA-Configuration.psm1') -Force

$modelResponse = [pscustomobject]@{
    id = 101
    type = 'LORA'
    modelVersions = @(
        [pscustomobject]@{ id = 201; name = 'old'; baseModel = 'Anima' }
        [pscustomobject]@{ id = 202; name = 'selected'; baseModel = 'Anima' }
    )
}
$versionResponse = [pscustomobject]@{
    id = 202
    modelId = 101
    model = [pscustomobject]@{ type = 'LORA'; name = 'Example Anima LoRA' }
    baseModel = 'Anima'
    trainedWords = @('example trigger', 'second trigger')
    downloadUrl = 'https://civitai.com/api/download/models/202'
    files = @(
        [pscustomobject]@{
            id = 301; name = 'preview.pt'; type = 'Model'; format = 'PickleTensor'; primary = $false
            virusScanResult = 'Success'; pickleScanResult = 'Success'; hashes = [pscustomobject]@{ SHA256 = ('1' * 64) }
        }
        [pscustomobject]@{
            id = 302; name = 'example-anima.safetensors'; type = 'Model'; format = 'SafeTensor'; primary = $true
            virusScanResult = 'Success'; pickleScanResult = 'Success'; hashes = [pscustomobject]@{ SHA256 = ('a' * 64) }
            downloadUrl = 'https://civitai.com/api/download/models/202?type=Model&format=SafeTensor'
        }
    )
}
$responses = @{
    'https://civitai.com/api/v1/models/101' = $modelResponse
    'https://civitai.com/api/v1/model-versions/202' = $versionResponse
}
$requestInvoker = {
    param($Uri, $Token)
    if ($Token -ne 'test-token') { throw 'The Civitai token was not forwarded to the API request invoker.' }
    if (-not $responses.ContainsKey($Uri)) { throw "Unexpected mock Civitai request: $Uri" }
    return $responses[$Uri]
}.GetNewClosure()

$entry = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/models/101/example?modelVersionId=202' `
    -Kind character `
    -Strength 0.8 `
    -Token 'test-token' `
    -RequestInvoker $requestInvoker
if ($entry.Name -ne 'example-anima.safetensors' -or $entry.Source -ne 'civitai' -or
    $entry.ModelId -ne 101 -or $entry.ModelVersionId -ne 202 -or $entry.BaseModel -ne 'Anima' -or
    $entry.AutoApplyInComfyUI -or -not $entry.Enabled -or [double]$entry.Strength -ne 0.8 -or
    @($entry.TriggerWords).Count -ne 2 -or $entry.Sha256 -ne ('a' * 64)) {
    throw 'A fixed Civitai LoRA was not normalized correctly.'
}
$serializedEntry = $entry | ConvertTo-Json -Depth 10
if ($serializedEntry.Contains('test-token')) { throw 'The Civitai token leaked into the normalized entry.' }

$currentVersionResponse = [pscustomobject]@{
    id = 2948641
    modelId = 2626310
    model = [pscustomobject]@{ type = 'LORA'; name = '748cm Style | KREA 2, Anima' }
    baseModel = 'Anima'
    trainedWords = @('@748cm_style')
    downloadUrl = 'https://civitai.com/api/download/models/2948641'
    files = @([pscustomobject]@{
        id = 2827897
        name = '748cm_TA_EP4 (1).safetensors'
        type = 'Model'
        metadata = [pscustomobject]@{ format = 'SafeTensor' }
        primary = $true
        virusScanResult = 'Success'
        pickleScanResult = 'Success'
        hashes = [pscustomobject]@{ SHA256 = 'D7B7E19EFE0462A84AB8953FF74D69A67BDF05E7F6A6351453451121AFDE98E3' }
        downloadUrl = 'https://civitai.com/api/download/models/2948641?fileId=2827897'
    })
}
$currentInvoker = {
    param($Uri, $Token)
    if ($Uri -ne 'https://civitai.com/api/v1/model-versions/2948641') { throw "Unexpected current Civitai fixture URI: $Uri" }
    return $currentVersionResponse
}.GetNewClosure()
$currentEntry = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/models/2626310/748cm-style-or-krea-2-anima?modelVersionId=2948641，' `
    -Kind style `
    -RequestInvoker $currentInvoker
if ($currentEntry.Name -ne '748cm_TA_EP4_1.safetensors' -or
    $currentEntry.OriginalFileName -ne '748cm_TA_EP4 (1).safetensors' -or
    [int64]$currentEntry.ModelId -ne 2626310 -or [int64]$currentEntry.ModelVersionId -ne 2948641 -or
    [int64]$currentEntry.FileId -ne 2827897 -or $currentEntry.BaseModel -ne 'Anima' -or
    $currentEntry.TriggerWords[0] -ne '@748cm_style' -or
    $currentEntry.Sha256 -ne 'd7b7e19efe0462a84ab8953ff74d69a67bdf05e7f6a6351453451121afde98e3' -or
    $currentEntry.Url -ne 'https://civitai.com/api/download/models/2948641?fileId=2827897') {
    throw 'The current Civitai API shape and pasted punctuation were not normalized correctly.'
}
$conflictingEntry = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/api/download/models/2948641' `
    -Kind style `
    -RequestInvoker $currentInvoker `
    -ExistingNames @('748cm_TA_EP4_1.safetensors')
if ($conflictingEntry.Name -ne '748cm_TA_EP4_1-v2948641-f2827897.safetensors') {
    throw 'A normalized Civitai filename conflict did not include the fixed version and file IDs.'
}

$selectedVersion = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/models/101/example' `
    -Kind style `
    -Token 'test-token' `
    -RequestInvoker $requestInvoker `
    -VersionSelector { param($Versions) return [int64]@($Versions)[1].id }
if ($selectedVersion.ModelVersionId -ne 202 -or $selectedVersion.Kind -ne 'style') {
    throw 'A version-less Civitai model page was not resolved through explicit selection.'
}

$downloadEntry = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/api/download/models/202' `
    -Kind style `
    -Token 'test-token' `
    -RequestInvoker $requestInvoker
if ($downloadEntry.ModelVersionId -ne 202) { throw 'A Civitai download URL did not preserve its exact version.' }

$direct = New-DirectLoRAEntry `
    -Url 'https://models.example.invalid/example.safetensors' `
    -Name 'direct-example.safetensors' `
    -Kind character `
    -Sha256 ('b' * 64) `
    -Strength 0.65 `
    -TriggerWords @('direct trigger')
if ($direct.Source -ne 'direct' -or $direct.AutoApplyInComfyUI -or $direct.BaseModel -notmatch 'Anima' -or
    $direct.TriggerWords[0] -ne 'direct trigger') {
    throw 'A direct HTTPS LoRA was not normalized as an install-only entry.'
}

function Assert-LoRARejected {
    param([scriptblock]$Action, [string]$Description)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid LoRA input was accepted: $Description" }
}

Assert-LoRARejected {
    Get-CivitaiLinkTarget -Url 'https://civitai.com/api/download/models/202?token=secret'
} 'token-bearing Civitai URL'
Assert-LoRARejected {
    Get-CivitaiLinkTarget -Url 'https://civitai.com/api/download/models/202#token=secret'
} 'fragment token-bearing Civitai URL'
Assert-LoRARejected {
    New-DirectLoRAEntry -Url 'http://example.invalid/file.safetensors' -Name 'file.safetensors' -Kind style -Sha256 ('c' * 64)
} 'non-HTTPS direct URL'
Assert-LoRARejected {
    New-DirectLoRAEntry -Url 'https://example.invalid/file.safetensors' -Name '../file.safetensors' -Kind style -Sha256 ('c' * 64)
} 'unsafe direct filename'
Assert-LoRARejected {
    New-DirectLoRAEntry -Url 'https://secret@example.invalid/file.safetensors' -Name 'file.safetensors' -Kind style -Sha256 ('c' * 64)
} 'credential-bearing direct URL'
Assert-LoRARejected {
    New-DirectLoRAEntry -Url 'https://example.invalid/file.safetensors#token=secret' -Name 'file.safetensors' -Kind style -Sha256 ('c' * 64)
} 'fragment token-bearing direct URL'
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/api/download/models/202' -Kind style -RequestInvoker { throw 'mock authentication failure' }
} 'Civitai authentication failure'

$credentialProject = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-civitai-credential-{0}" -f [guid]::NewGuid().ToString('N'))
$credentialEnvironmentName = 'VAST_ANIMA_TEST_CIVITAI_TOKEN'
$previousCredentialEnvironment = [Environment]::GetEnvironmentVariable($credentialEnvironmentName, 'Process')
try {
    $testToken = 'test_civitai_key-12345'
    $secureToken = ConvertTo-SecureString -String $testToken -AsPlainText -Force
    if (-not (Test-CivitaiDownloadCredential -SecureToken $secureToken -DownloadUrl 'https://civitai.com/api/download/models/202' -RequestInvoker {
        param($Uri, $Token)
        if ($Uri -ne 'https://civitai.com/api/download/models/202' -or $Token -ne 'test_civitai_key-12345') { throw 'Credential validation leaked or changed its inputs.' }
        return 302
    })) { throw 'A valid authenticated Civitai download redirect was rejected.' }
    Assert-LoRARejected {
        Test-CivitaiDownloadCredential -SecureToken $secureToken -DownloadUrl 'https://civitai.com/api/download/models/202' -RequestInvoker { return 401 }
    } 'Civitai API Key rejected by download endpoint'

    $credentialPath = Set-CivitaiStoredCredential -ProjectRoot $credentialProject -SecureToken $secureToken
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'The encrypted Civitai credential file was not created.' }
    if ([IO.File]::ReadAllText($credentialPath).Contains($testToken)) { throw 'The Civitai API Key was stored in plaintext.' }
    if ((Get-CivitaiStoredCredential -ProjectRoot $credentialProject) -ne $testToken) { throw 'The current Windows user could not decrypt the stored Civitai credential.' }
    if ($env:OS -eq 'Windows_NT') {
        $credentialAcl = Get-Acl -LiteralPath $credentialPath
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $unexpectedRules = @($credentialAcl.Access | Where-Object { $_.IdentityReference.Value -ne $currentIdentity })
        if (-not $credentialAcl.AreAccessRulesProtected -or $unexpectedRules.Count -gt 0) {
            throw 'The stored Civitai credential ACL is not restricted to the current Windows user.'
        }
    }

    $replacementToken = 'replacement-test-token-456'
    $replacementSecureToken = ConvertTo-SecureString -String $replacementToken -AsPlainText -Force
    Set-CivitaiStoredCredential -ProjectRoot $credentialProject -SecureToken $replacementSecureToken | Out-Null
    if ((Get-CivitaiStoredCredential -ProjectRoot $credentialProject) -ne $replacementToken) { throw 'An existing stored Civitai credential could not be replaced.' }

    [Environment]::SetEnvironmentVariable($credentialEnvironmentName, 'environment-key', 'Process')
    $credential = Get-CivitaiCredential -ProjectRoot $credentialProject -EnvironmentVariableName $credentialEnvironmentName
    if ($credential.Source -ne 'stored' -or $credential.Value -ne $replacementToken) { throw 'The saved Civitai credential did not take precedence over the process environment.' }
    Remove-CivitaiStoredCredential -ProjectRoot $credentialProject
    $credential = Get-CivitaiCredential -ProjectRoot $credentialProject -EnvironmentVariableName $credentialEnvironmentName
    if ($credential.Source -ne 'environment' -or $credential.Value -ne 'environment-key') { throw 'The Civitai environment fallback was not preserved.' }
} finally {
    [Environment]::SetEnvironmentVariable($credentialEnvironmentName, $previousCredentialEnvironment, 'Process')
    if (Test-Path -LiteralPath $credentialProject) { Remove-Item -LiteralPath $credentialProject -Recurse -Force }
}

$wrongParent = $versionResponse.PSObject.Copy()
$wrongParent.modelId = 999
$wrongParentResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $wrongParent }
$wrongParentInvoker = { param($Uri, $Token) return $wrongParentResponses[$Uri] }.GetNewClosure()
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/models/101/example?modelVersionId=202' -Kind style -RequestInvoker $wrongParentInvoker
} 'model/version ownership mismatch'

$wrongType = $versionResponse.PSObject.Copy()
$wrongType.model = [pscustomobject]@{ type = 'Checkpoint' }
$wrongTypeResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $wrongType }
$wrongTypeInvoker = { param($Uri, $Token) return $wrongTypeResponses[$Uri] }.GetNewClosure()
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/api/download/models/202' -Kind style -RequestInvoker $wrongTypeInvoker
} 'non-LoRA Civitai resource'

$wrongBase = $versionResponse.PSObject.Copy()
$wrongBase.baseModel = 'SDXL 1.0'
$wrongBaseResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $wrongBase }
$wrongBaseInvoker = { param($Uri, $Token) return $wrongBaseResponses[$Uri] }.GetNewClosure()
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/api/download/models/202' -Kind style -RequestInvoker $wrongBaseInvoker
} 'non-Anima Civitai resource'

$dangerous = $versionResponse.PSObject.Copy()
$dangerous.files = @($versionResponse.files[1].PSObject.Copy())
$dangerous.files[0].virusScanResult = 'Danger'
$dangerousResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $dangerous }
$dangerousInvoker = { param($Uri, $Token) return $dangerousResponses[$Uri] }.GetNewClosure()
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/api/download/models/202' -Kind style -RequestInvoker $dangerousInvoker
} 'dangerous Civitai scan result'

$missingHash = $versionResponse.PSObject.Copy()
$missingHash.files = @($versionResponse.files[1].PSObject.Copy())
$missingHash.files[0].hashes = [pscustomobject]@{}
$missingHashResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $missingHash }
$missingHashInvoker = { param($Uri, $Token) return $missingHashResponses[$Uri] }.GetNewClosure()
Assert-LoRARejected {
    Resolve-CivitaiLoRAEntry -Url 'https://civitai.com/api/download/models/202' -Kind style -RequestInvoker $missingHashInvoker
} 'missing Civitai SHA-256'

$multipleFiles = $versionResponse.PSObject.Copy()
$firstSafe = $versionResponse.files[1].PSObject.Copy()
$firstSafe.id = 401; $firstSafe.name = 'first.safetensors'; $firstSafe.primary = $false
$secondSafe = $versionResponse.files[1].PSObject.Copy()
$secondSafe.id = 402; $secondSafe.name = 'second.safetensors'; $secondSafe.primary = $false
$multipleFiles.files = @($firstSafe, $secondSafe)
$multipleResponses = @{ 'https://civitai.com/api/v1/model-versions/202' = $multipleFiles }
$multipleInvoker = { param($Uri, $Token) return $multipleResponses[$Uri] }.GetNewClosure()
$selectedFile = Resolve-CivitaiLoRAEntry `
    -Url 'https://civitai.com/api/download/models/202' `
    -Kind style `
    -RequestInvoker $multipleInvoker `
    -FileSelector { param($Files) return @($Files)[1] }
if ($selectedFile.Name -ne 'second.safetensors') { throw 'Explicit Civitai file selection was not honored.' }

$localProject = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-local-lora-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $configuredDirectory = Resolve-LocalLoRADirectory -ProjectRoot $localProject -RelativePath 'user-config/loras' -Create
    if ((Resolve-LocalLoRADirectory -ProjectRoot $localProject -RelativePath 'user-config/loras/') -ne $configuredDirectory) {
        throw 'A harmless trailing local-LoRA directory separator was not normalized.'
    }
    $nested = Join-Path $configuredDirectory '画风 Styles'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $configuredDirectory 'character one.safetensors'), [byte[]](1, 2, 3, 4))
    [System.IO.File]::WriteAllBytes((Join-Path $nested '风格（测试）.safetensors'), [byte[]](5, 6, 7))
    [System.IO.File]::WriteAllText((Join-Path $configuredDirectory 'ignore.txt'), 'ignored')
    $localFiles = @(Get-LocalLoRAFiles -ProjectRoot $localProject -RelativeDirectory 'user-config/loras')
    if ($localFiles.Count -ne 2 -or
        'character one.safetensors' -notin @($localFiles.RelativePath) -or
        '画风 Styles/风格（测试）.safetensors' -notin @($localFiles.RelativePath) -or
        @($localFiles | Where-Object { $_.Sha256 -notmatch '^[0-9a-f]{64}$' -or $_.StagingId -notmatch '^[0-9a-f]{64}$' }).Count -gt 0) {
        throw 'Recursive project-local LoRA discovery did not preserve safe relative paths and hashes.'
    }
    Assert-LoRARejected {
        Resolve-LocalLoRADirectory -ProjectRoot $localProject -RelativePath '../outside' | Out-Null
    } 'local LoRA directory traversal'
    Assert-LoRARejected {
        Resolve-LocalLoRADirectory -ProjectRoot $localProject -RelativePath '.git/loras' | Out-Null
    } 'local LoRA directory inside Git metadata'
    [System.IO.File]::WriteAllBytes((Join-Path $configuredDirectory 'empty.safetensors'), [byte[]]@())
    Assert-LoRARejected {
        Get-LocalLoRAFiles -ProjectRoot $localProject -RelativeDirectory 'user-config/loras' | Out-Null
    } 'empty local LoRA file'
} finally {
    if (Test-Path -LiteralPath $localProject) { Remove-Item -LiteralPath $localProject -Recurse -Force }
}

$managerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Manage-LoRAConfiguration.ps1') -Raw -Encoding UTF8
$entryText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-VastAnima.ps1') -Raw -Encoding UTF8
foreach ($expected in @('添加 Civitai LoRA', '添加公开 HTTPS 直链', 'AutoApplyInComfyUI', '不会删除远端文件', 'Get-LoRAInstallationStatus', '本地配置无效', '设置本地 LoRA 目录', '打开本地 LoRA 目录', '仅安装', '录入 Civitai API Key', '清除 Civitai API Key', 'Test-CivitaiDownloadCredential')) {
    if (-not $managerText.Contains($expected)) { throw "The LoRA manager is missing expected behavior: $expected" }
}
if (-not $entryText.Contains("'13' = 'ManageLoRA'") -or -not $entryText.Contains('Manage-LoRAConfiguration.ps1')) {
    throw 'The main menu does not expose LoRA management.'
}

Write-Host 'Civitai and direct LoRA configuration management passed.' -ForegroundColor Green
