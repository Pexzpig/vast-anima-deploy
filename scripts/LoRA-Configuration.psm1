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
            throw "Civitai API refused access ($statusCode). Save a Civitai API Key from ManageLoRA, or set CIVITAI_API_TOKEN in the current PowerShell process, and retry."
        }
        throw "Civitai API request failed: $Uri. $($_.Exception.Message)"
    }
}

function Get-CivitaiCredentialPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path ([System.IO.Path]::GetFullPath($ProjectRoot)) 'user-config\civitai-token.secret'
}

function Set-RestrictedCredentialAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($env:OS -eq 'Windows_NT') {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $Path '/inheritance:r' '/grant:r' "${identity}:(F)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions for Civitai credential: $Path" }
    } else {
        & chmod 600 -- $Path
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions for Civitai credential: $Path" }
    }
}

function ConvertFrom-CivitaiSecureString {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Assert-CivitaiTokenValue {
    param([Parameter(Mandatory = $true)][string]$Token)

    if ($Token -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Civitai API Key is empty or contains unsupported characters.'
    }
}

function Set-CivitaiStoredCredential {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][Security.SecureString]$SecureToken
    )

    $plainToken = ConvertFrom-CivitaiSecureString -SecureValue $SecureToken
    try { Assert-CivitaiTokenValue -Token $plainToken } finally { $plainToken = $null }
    $encrypted = ConvertFrom-SecureString -SecureString $SecureToken
    if (-not $encrypted) { throw 'PowerShell could not encrypt the Civitai API Key.' }
    $path = Get-CivitaiCredentialPath -ProjectRoot $ProjectRoot
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = Join-Path $directory (".civitai-token-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $encrypted, (New-Object Text.UTF8Encoding($false)))
        Set-RestrictedCredentialAcl -Path $temporaryPath
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
        Set-RestrictedCredentialAcl -Path $path
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

function Get-CivitaiStoredCredential {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Get-CivitaiCredentialPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $encrypted = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).Trim()
        $secure = ConvertTo-SecureString -String $encrypted
        $token = ConvertFrom-CivitaiSecureString -SecureValue $secure
        Assert-CivitaiTokenValue -Token $token
        return $token
    } catch {
        throw "Stored Civitai credential cannot be decrypted by the current Windows user. Re-enter it from ManageLoRA. $($_.Exception.Message)"
    }
}

function Get-CivitaiCredential {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvironmentVariableName
    )

    $stored = Get-CivitaiStoredCredential -ProjectRoot $ProjectRoot
    if ($stored) { return [pscustomobject]@{ Value = $stored; Source = 'stored' } }
    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariableName, 'Process')
    if ($environmentValue) {
        Assert-CivitaiTokenValue -Token $environmentValue
        return [pscustomobject]@{ Value = $environmentValue; Source = 'environment' }
    }
    return $null
}

function Remove-CivitaiStoredCredential {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Get-CivitaiCredentialPath -ProjectRoot $ProjectRoot
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}

function Test-CivitaiDownloadCredential {
    param(
        [Parameter(Mandatory = $true)][Security.SecureString]$SecureToken,
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [scriptblock]$RequestInvoker
    )

    $uri = $null
    if (-not [Uri]::TryCreate($DownloadUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -notin @('civitai.com', 'www.civitai.com')) {
        throw 'Civitai credential validation requires a civitai.com HTTPS download URL.'
    }
    $token = ConvertFrom-CivitaiSecureString -SecureValue $SecureToken
    try {
        Assert-CivitaiTokenValue -Token $token
        if ($RequestInvoker) { $statusCode = [int](& $RequestInvoker $uri.AbsoluteUri $token) }
        else {
            try {
                $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -Method Get -Headers @{
                    Authorization = "Bearer $token"
                    Range = 'bytes=0-0'
                } `
                    -MaximumRedirection 0 -TimeoutSec 45 -UserAgent 'vast-anima-deploy/1'
                $statusCode = [int]$response.StatusCode
            } catch {
                $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($statusCode -eq 0) { throw "Could not validate the Civitai API Key. $($_.Exception.Message)" }
            }
        }
    } finally {
        $token = $null
    }
    if ($statusCode -in @(200, 206, 301, 302, 303, 307, 308)) { return $true }
    if ($statusCode -in @(401, 403)) { throw "Civitai rejected the API Key with HTTP $statusCode." }
    throw "Civitai credential validation returned unexpected HTTP $statusCode."
}

function Get-CivitaiLinkTarget {
    param([Parameter(Mandatory = $true)][string]$Url)

    $normalizedUrl = [regex]::Replace(
        $Url.Trim(),
        '(?i)([?&]modelVersionId=\d+)[,，。；;：:\)\]】）]+$',
        '$1'
    )
    $uri = $null
    if (-not [Uri]::TryCreate($normalizedUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
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

function ConvertTo-SafeCivitaiLoRAFileName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int64]$VersionId,
        [Parameter(Mandatory = $true)][int64]$FileId,
        [string[]]$ExistingNames = @()
    )

    if ($Name -match '[/\\]' -or $Name -notmatch '(?i)\.safetensors$') {
        throw "Unsafe LoRA filename returned by Civitai: $Name"
    }
    $stem = $Name.Substring(0, $Name.Length - '.safetensors'.Length)
    $safeStem = [regex]::Replace($stem, '[^A-Za-z0-9._-]+', '_')
    $safeStem = [regex]::Replace($safeStem, '_+', '_').Trim([char[]]'._-')
    if (-not $safeStem) { $safeStem = "civitai-$VersionId-$FileId" }
    $safeName = "$safeStem.safetensors"

    $names = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($existingName in @($ExistingNames)) {
        if ($existingName) { [void]$names.Add([string]$existingName) }
    }
    if ($names.Contains($safeName)) {
        $safeName = "$safeStem-v$VersionId-f$FileId.safetensors"
        if ($names.Contains($safeName)) {
            throw "Civitai LoRA filename still conflicts after adding version and file IDs: $safeName"
        }
    }
    return $safeName
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
        [scriptblock]$FileSelector,
        [string[]]$ExistingNames = @()
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
        if (-not $format) {
            $metadata = Get-LoRAProperty -Object $_ -Names @('metadata')
            $format = [string](Get-LoRAProperty -Object $metadata -Names @('format'))
        }
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

    $originalName = [string](Get-LoRAProperty -Object $selectedFile -Names @('name'))
    $fileId = [int64](Get-LoRAProperty -Object $selectedFile -Names @('id') -Default 0)
    if ($fileId -le 0) { throw "Civitai did not provide a valid file ID for $originalName." }
    $name = ConvertTo-SafeCivitaiLoRAFileName `
        -Name $originalName `
        -VersionId ([int64]$versionId) `
        -FileId $fileId `
        -ExistingNames $ExistingNames
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
        FileId = $fileId
        OriginalFileName = $originalName
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
        FileId = $null
        OriginalFileName = $Name
        BaseModel = 'Anima (user confirmed)'
        TriggerWords = @($TriggerWords | ForEach-Object { [string]$_ } | Where-Object { $_ })
        AutoApplyInComfyUI = $false
    }
}

function Resolve-LocalLoRADirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$Create
    )

    $normalizedRelativePath = $RelativePath.Trim().TrimEnd([char[]]'\/')
    if ([string]::IsNullOrWhiteSpace($normalizedRelativePath) -or [System.IO.Path]::IsPathRooted($normalizedRelativePath)) {
        throw 'Local.LoRADirectory must be a project-relative directory.'
    }
    $segments = @($normalizedRelativePath -split '[/\\]')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { -not $_ -or $_ -in @('.', '..') }).Count -gt 0) {
        throw 'Local.LoRADirectory contains an unsafe path segment.'
    }
    if ($segments[0] -ieq '.git') { throw 'Local.LoRADirectory must not be stored inside .git.' }

    $root = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char[]]'\/')
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $root $normalizedRelativePath)).TrimEnd([char[]]'\/')
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local.LoRADirectory must remain inside the project root.'
    }

    $cursor = $root
    foreach ($segment in $segments) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Local.LoRADirectory must not traverse a symlink or junction: $cursor"
            }
        }
    }
    if ($Create -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }
    return $resolved
}

function Get-LocalLoRAFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RelativeDirectory,
        [switch]$CreateDirectory
    )

    $root = Resolve-LocalLoRADirectory -ProjectRoot $ProjectRoot -RelativePath $RelativeDirectory -Create:$CreateDirectory
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $rootPrefix = $root.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
    $relativePaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -ieq '.safetensors' } | Sort-Object FullName)) {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Local LoRA files must not be symlinks: $($file.FullName)"
        }
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Local LoRA resolved outside its configured directory: $fullPath"
        }
        $relativePath = $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
        $pathCursor = $root
        foreach ($segment in @($relativePath -split '/')) {
            $controlCharacters = @($segment.ToCharArray() | Where-Object { [char]::IsControl($_) })
            if (-not $segment -or $segment -in @('.', '..') -or $controlCharacters.Count -gt 0) {
                throw "Local LoRA contains an unsafe relative path: $relativePath"
            }
            $pathCursor = Join-Path $pathCursor $segment
            $pathItem = Get-Item -LiteralPath $pathCursor -Force
            if (($pathItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Local LoRA paths must not traverse a symlink or junction: $pathCursor"
            }
        }
        if (-not $relativePaths.Add($relativePath)) { throw "Duplicate local LoRA relative path: $relativePath" }
        if ($file.Length -le 0) { throw "Local LoRA file is empty: $relativePath" }
        $sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $material = [System.Text.Encoding]::UTF8.GetBytes("$relativePath`n$sha256")
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stagingId = ([System.BitConverter]::ToString($algorithm.ComputeHash($material))).Replace('-', '').ToLowerInvariant()
        } finally {
            $algorithm.Dispose()
        }
        $items += [pscustomobject]@{
            LocalPath = $fullPath
            RelativePath = $relativePath
            Sha256 = $sha256
            SizeBytes = [int64]$file.Length
            StagingId = $stagingId
        }
    }
    return $items
}

Export-ModuleMember -Function `
    Get-CivitaiLinkTarget, Get-CivitaiModelVersions, Resolve-CivitaiLoRAEntry, New-DirectLoRAEntry, `
    Resolve-LocalLoRADirectory, Get-LocalLoRAFiles, Get-CivitaiCredentialPath, Set-CivitaiStoredCredential, `
    Get-CivitaiStoredCredential, Get-CivitaiCredential, Remove-CivitaiStoredCredential, Test-CivitaiDownloadCredential
