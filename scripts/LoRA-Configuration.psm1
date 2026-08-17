Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LoRAProperty {
    param($Object, [string[]]$Names, $Default = $null)

    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            return $Object[$name]
        }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Invoke-CivitaiApiRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token,
        [scriptblock]$RequestInvoker
    )

    if ($RequestInvoker) { return & $RequestInvoker $Uri $Token }
    $headers = @{ Accept = 'application/json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -TimeoutSec 45 -UserAgent 'vast-anima-deploy/1'
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -in @(401, 403)) {
            throw "Civitai API refused access ($statusCode). Set CIVITAI_API_TOKEN in the current PowerShell process and retry."
        }
        throw "Civitai API request failed: $Uri. $($_.Exception.Message)"
    }
}

function Get-CivitaiLinkTarget {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'Civitai links must be absolute HTTPS URLs.'
    }
    if ($uri.Host -notin @('civitai.com', 'www.civitai.com')) {
        throw "Unsupported Civitai host: $($uri.Host)"
    }
    if ($uri.UserInfo) { throw 'Civitai links must not contain embedded credentials.' }
    if ($uri.AbsoluteUri -match '(?i)(?:[?&#]|^)token=') {
        throw 'Do not include a Civitai token in the URL; use CIVITAI_API_TOKEN.'
    }

    $modelId = $null
    $versionId = $null
    if ($uri.AbsolutePath -match '^/models/(\d+)(?:/|$)') { $modelId = [int64]$Matches[1] }
    if ($uri.AbsolutePath -match '^/api/download/models/(\d+)(?:/|$)') { $versionId = [int64]$Matches[1] }
    if ($uri.AbsolutePath -match '^/api/v1/model-versions/(\d+)(?:/|$)') { $versionId = [int64]$Matches[1] }
    if ($uri.Query -match '(?i)(?:^|[?&])modelVersionId=(\d+)(?:&|$)') { $versionId = [int64]$Matches[1] }
    if ($null -eq $modelId -and $null -eq $versionId) {
        throw 'The link must be a Civitai model page, model-version API URL, or /api/download/models/{versionId} URL.'
    }

    return [pscustomobject]@{
        ModelId = $modelId
        ModelVersionId = $versionId
        OriginalUrl = $uri.AbsoluteUri
    }
}

function Get-CivitaiModelVersions {
    param(
        [Parameter(Mandatory = $true)][int64]$ModelId,
        [string]$Token,
        [scriptblock]$RequestInvoker
    )

    $model = Invoke-CivitaiApiRequest -Uri "https://civitai.com/api/v1/models/$ModelId" -Token $Token -RequestInvoker $RequestInvoker
    $modelType = [string](Get-LoRAProperty -Object $model -Names @('type'))
    if ($modelType.ToUpperInvariant() -ne 'LORA') { throw "Civitai model $ModelId is '$modelType', not a LoRA." }
    $versions = @(Get-LoRAProperty -Object $model -Names @('modelVersions') -Default @())
    if ($versions.Count -eq 0) { throw "Civitai model $ModelId has no downloadable versions." }
    return $versions
}

function Resolve-CivitaiLoRAEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][ValidateSet('character', 'style')][string]$Kind,
        [ValidateRange(-2.0, 2.0)][double]$Strength = 1.0,
        [Nullable[int64]]$SelectedVersionId,
        [Nullable[int64]]$SelectedFileId,
        [string]$Token,
        [scriptblock]$RequestInvoker,
        [scriptblock]$VersionSelector,
        [scriptblock]$FileSelector
    )

    $target = Get-CivitaiLinkTarget -Url $Url
    $versionId = $target.ModelVersionId
    if ($null -ne $SelectedVersionId) { $versionId = [int64]$SelectedVersionId }
    if ($null -eq $versionId) {
        $versions = @(Get-CivitaiModelVersions -ModelId $target.ModelId -Token $Token -RequestInvoker $RequestInvoker)
        if ($VersionSelector) {
            $versionId = [int64](& $VersionSelector $versions)
        } elseif ($versions.Count -eq 1) {
            $versionId = [int64](Get-LoRAProperty -Object $versions[0] -Names @('id'))
        } else {
            throw 'This model page has multiple versions. Select an exact model-version ID.'
        }
    }

    $version = Invoke-CivitaiApiRequest -Uri "https://civitai.com/api/v1/model-versions/$versionId" -Token $Token -RequestInvoker $RequestInvoker
    $model = Get-LoRAProperty -Object $version -Names @('model')
    $modelId = Get-LoRAProperty -Object $version -Names @('modelId') -Default $target.ModelId
    if ($null -eq $modelId -or [int64]$modelId -le 0) { throw "Civitai model version $versionId did not identify its parent model." }
    if ($null -ne $target.ModelId -and [int64]$target.ModelId -ne [int64]$modelId) {
        throw "Civitai model version $versionId does not belong to model $($target.ModelId)."
    }
    $modelType = [string](Get-LoRAProperty -Object $model -Names @('type'))
    if (-not $modelType -and $null -ne $modelId) {
        $modelDetails = Invoke-CivitaiApiRequest -Uri "https://civitai.com/api/v1/models/$modelId" -Token $Token -RequestInvoker $RequestInvoker
        $modelType = [string](Get-LoRAProperty -Object $modelDetails -Names @('type'))
    }
    if ($modelType.ToUpperInvariant() -ne 'LORA') { throw "Civitai model version $versionId is '$modelType', not a LoRA." }

    $baseModel = [string](Get-LoRAProperty -Object $version -Names @('baseModel'))
    if ($baseModel -notmatch '(?i)\bAnima\b') {
        throw "Civitai model version $versionId targets '$baseModel', not Anima."
    }

    $files = @(Get-LoRAProperty -Object $version -Names @('files') -Default @())
    $candidates = @($files | Where-Object {
        $name = [string](Get-LoRAProperty -Object $_ -Names @('name'))
        $format = [string](Get-LoRAProperty -Object $_ -Names @('format'))
        $type = [string](Get-LoRAProperty -Object $_ -Names @('type'))
        $name -match '(?i)\.safetensors$' -and $format -match '(?i)^SafeTensor$' -and ($type -eq '' -or $type -eq 'Model')
    })
    if ($candidates.Count -eq 0) { throw "Civitai model version $versionId has no SafeTensor LoRA file." }

    $selectedFile = $null
    if ($null -ne $SelectedFileId) {
        $selectedFile = @($candidates | Where-Object { [int64](Get-LoRAProperty -Object $_ -Names @('id') -Default 0) -eq [int64]$SelectedFileId }) | Select-Object -First 1
    } else {
        $primary = @($candidates | Where-Object { [bool](Get-LoRAProperty -Object $_ -Names @('primary') -Default $false) })
        if ($primary.Count -eq 1) { $selectedFile = $primary[0] }
        elseif ($candidates.Count -eq 1) { $selectedFile = $candidates[0] }
        elseif ($FileSelector) { $selectedFile = & $FileSelector $candidates }
    }
    if ($null -eq $selectedFile) { throw 'The selected Civitai version has multiple SafeTensor files. Select an exact file.' }

    $name = [string](Get-LoRAProperty -Object $selectedFile -Names @('name'))
    if ($name -notmatch '^[A-Za-z0-9._-]+\.safetensors$') { throw "Unsafe LoRA filename returned by Civitai: $name" }
    foreach ($scanName in @('virusScanResult', 'pickleScanResult')) {
        $scan = [string](Get-LoRAProperty -Object $selectedFile -Names @($scanName))
        if ($scan -match '(?i)^(Danger|Error|Failed)$') { throw "Civitai rejected $name because $scanName is '$scan'." }
    }
    $hashes = Get-LoRAProperty -Object $selectedFile -Names @('hashes')
    $sha256 = [string](Get-LoRAProperty -Object $hashes -Names @('SHA256', 'sha256'))
    if ($sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Civitai did not provide a SHA-256 for $name." }

    $downloadUrl = [string](Get-LoRAProperty -Object $selectedFile -Names @('downloadUrl'))
    if (-not $downloadUrl) { $downloadUrl = [string](Get-LoRAProperty -Object $version -Names @('downloadUrl')) }
    if (-not $downloadUrl) { $downloadUrl = "https://civitai.com/api/download/models/$versionId" }
    $downloadUri = $null
    if (-not [Uri]::TryCreate($downloadUrl, [UriKind]::Absolute, [ref]$downloadUri) -or
        $downloadUri.Scheme -ne 'https' -or $downloadUri.UserInfo -or $downloadUri.Host -notin @('civitai.com', 'www.civitai.com')) {
        throw "Civitai returned an unsafe download URL for $name."
    }
    if ($downloadUri.AbsoluteUri -match '(?i)(?:[?&#]|^)token=') { throw 'Civitai returned a token-bearing URL; refusing to persist it.' }

    $triggerWords = @(Get-LoRAProperty -Object $version -Names @('trainedWords') -Default @() | ForEach-Object { [string]$_ } | Where-Object { $_ })
    return [ordered]@{
        Name = $name
        Kind = $Kind
        Url = $downloadUri.AbsoluteUri
        Sha256 = $sha256.ToLowerInvariant()
        Strength = $Strength
        Enabled = $true
        Source = 'civitai'
        SourcePageUrl = "https://civitai.com/models/${modelId}?modelVersionId=$versionId"
        ModelId = if ($null -eq $modelId) { $null } else { [int64]$modelId }
        ModelVersionId = [int64]$versionId
        BaseModel = $baseModel
        TriggerWords = $triggerWords
        AutoApplyInComfyUI = $false
    }
}

function New-DirectLoRAEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('character', 'style')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [ValidateRange(-2.0, 2.0)][double]$Strength = 1.0,
        [string[]]$TriggerWords = @()
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { throw 'Direct LoRA URLs must use HTTPS.' }
    if ($uri.UserInfo) { throw 'Direct LoRA URLs must not contain embedded credentials.' }
    if ($uri.AbsoluteUri -match '(?i)(?:[?&#]|^)token=') { throw 'Do not store access tokens in LoRA URLs.' }
    if ($Name -notmatch '^[A-Za-z0-9._-]+\.safetensors$') { throw "Unsafe LoRA filename: $Name" }
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Direct LoRA entries require a 64-character SHA-256.' }
    return [ordered]@{
        Name = $Name
        Kind = $Kind
        Url = $uri.AbsoluteUri
        Sha256 = $Sha256.ToLowerInvariant()
        Strength = $Strength
        Enabled = $true
        Source = 'direct'
        SourcePageUrl = ''
        ModelId = $null
        ModelVersionId = $null
        BaseModel = 'Anima (user confirmed)'
        TriggerWords = @($TriggerWords | ForEach-Object { [string]$_ } | Where-Object { $_ })
        AutoApplyInComfyUI = $false
    }
}

Export-ModuleMember -Function Get-CivitaiLinkTarget, Get-CivitaiModelVersions, Resolve-CivitaiLoRAEntry, New-DirectLoRAEntry
