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

$managerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Manage-LoRAConfiguration.ps1') -Raw -Encoding UTF8
$entryText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-VastAnima.ps1') -Raw -Encoding UTF8
foreach ($expected in @('添加 Civitai LoRA', '添加公开 HTTPS 直链', 'AutoApplyInComfyUI', '不会删除远端文件', 'Get-LoRAInstallationStatus', '本地配置无效')) {
    if (-not $managerText.Contains($expected)) { throw "The LoRA manager is missing expected behavior: $expected" }
}
if (-not $entryText.Contains("'13' = 'ManageLoRA'") -or -not $entryText.Contains('Manage-LoRAConfiguration.ps1')) {
    throw 'The main menu does not expose LoRA management.'
}

Write-Host 'Civitai and direct LoRA configuration management passed.' -ForegroundColor Green
