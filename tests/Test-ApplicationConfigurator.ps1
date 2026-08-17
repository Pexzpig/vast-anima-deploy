[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\Common.ps1')

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configurator = Join-Path $projectRoot 'remote\configure-application.py'
$fixture = Join-Path $PSScriptRoot 'fixtures\anima-workflow-minimal.json'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-anima-app-config-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    $original = Join-Path $temporaryRoot 'original.json'
    $managed = Join-Path $temporaryRoot 'managed.json'
    $installed = Join-Path $temporaryRoot 'installed.json'
    $hiresManaged = Join-Path $temporaryRoot 'hires-managed.json'
    $hiresInstalled = Join-Path $temporaryRoot 'hires-installed.json'
    $remoteConfigPath = Join-Path $temporaryRoot 'remote-config.json'
    Copy-Item -LiteralPath $fixture -Destination $original
    $originalHash = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash

    $remoteConfig = [ordered]@{
        anima = [ordered]@{
            models = @(
                @{ Name = 'anima-base-v1.0.safetensors' },
                @{ Name = 'qwen_3_06b_base.safetensors' },
                @{ Name = 'qwen_image_vae.safetensors' }
            )
            baseline = [ordered]@{
                Width = 1280; Height = 768; Steps = 41; Cfg = 5.25; Seed = 987654
                Sampler = 'er_sde'; Scheduler = 'simple'
                PositivePrompt = 'configured positive'; NegativePrompt = 'configured negative'
            }
            turbo = [ordered]@{
                name = 'anima-turbo-lora-v0.2.safetensors'; strength = 1.0
                steps = 8; cfg = 1.0; enabled_by_default = $false
            }
            managed_loras = @(
                @{ Name = 'character-test.safetensors'; Kind = 'character'; Strength = 0.75; Enabled = $true; AutoApplyInComfyUI = $true }
                @{ Name = 'install-only-style.safetensors'; Kind = 'style'; Strength = 0.9; Enabled = $true; AutoApplyInComfyUI = $false }
                @{ Name = 'disabled-style.safetensors'; Kind = 'style'; Strength = 1.0; Enabled = $false }
            )
            manual_lora_slots = 2
            hires = [ordered]@{
                scale = 1.5; upscale_method = 'bislerp'; steps = 20; cfg = 4.5
                sampler = 'er_sde'; scheduler = 'simple'; denoise = 0.35
            }
        }
        webui = [ordered]@{
            localization = 'zh_CN'
            extensions = @(
                @{ Name = 'tag-autocomplete'; Enabled = $true },
                @{ Name = 'stable-diffusion-webui-localization-zh_CN'; Enabled = $true }
            )
        }
    }
    Save-JsonFile -Value $remoteConfig -Path $remoteConfigPath | Out-Null

    & python $configurator configure-workflow $remoteConfigPath $original $managed $installed $hiresManaged $hiresInstalled
    if ($LASTEXITCODE -ne 0) { throw 'configure-workflow failed.' }
    & python $configurator verify-workflow $remoteConfigPath $original $managed $installed $hiresManaged $hiresInstalled
    if ($LASTEXITCODE -ne 0) { throw 'verify-workflow failed.' }

    if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $originalHash) {
        throw 'The original workflow was modified.'
    }
    $firstManagedHash = (Get-FileHash -LiteralPath $managed -Algorithm SHA256).Hash
    $firstHiresHash = (Get-FileHash -LiteralPath $hiresManaged -Algorithm SHA256).Hash
    & python $configurator configure-workflow $remoteConfigPath $original $managed $installed $hiresManaged $hiresInstalled
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $managed -Algorithm SHA256).Hash -ne $firstManagedHash -or
        (Get-FileHash -LiteralPath $hiresManaged -Algorithm SHA256).Hash -ne $firstHiresHash) {
        throw 'Managed workflow generation is not idempotent.'
    }

    $workflow = Get-Content -LiteralPath $managed -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($workflow.nodes | Where-Object type -eq 'ResolutionSelector').Count -ne 0 -or @($workflow.links | Where-Object id -in @(138, 139)).Count -ne 0) {
        throw 'ResolutionSelector still overrides configured width and height.'
    }
    $instanceNode = @($workflow.nodes | Where-Object id -eq 90)[0]
    if (@($instanceNode.inputs | Where-Object { $_.name -in @('width', 'height') -and $null -ne $_.link }).Count -ne 0) {
        throw 'Subgraph width or height input is still linked to the selector.'
    }
    $nodes = @($workflow.definitions.subgraphs[0].nodes)
    $latent = @($nodes | Where-Object type -eq 'EmptyLatentImage')[0]
    $sampler = @($nodes | Where-Object type -eq 'KSampler')[0]
    $positive = @($nodes | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -like '*Positive Prompt*' })[0]
    $negative = @($nodes | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -like '*Negative Prompt*' })[0]
    $baseSteps = @($nodes | Where-Object id -eq 79)[0]
    $turboSteps = @($nodes | Where-Object id -eq 81)[0]
    $baseCfg = @($nodes | Where-Object id -eq 86)[0]
    $turboCfg = @($nodes | Where-Object id -eq 88)[0]
    $turboSwitch = @($nodes | Where-Object type -eq 'PrimitiveBoolean')[0]
    $loraLoaders = @($nodes | Where-Object type -eq 'LoraLoaderModelOnly')
    $workflowJson = $workflow | ConvertTo-Json -Depth 100 -Compress
    $turboLoader = @($loraLoaders | Where-Object id -eq 83)[0]
    $managedCharacter = @($loraLoaders | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -eq 'Managed Character LoRA' })[0]
    $manualCharacter = @($loraLoaders | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -like 'Character LoRA*' })[0]
    $manualStyle = @($loraLoaders | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -like 'Style LoRA*' })[0]
    if ($latent.widgets_values[0] -ne 1280 -or $latent.widgets_values[1] -ne 768 -or
        $sampler.widgets_values[0] -ne 987654 -or $sampler.widgets_values[1] -ne 'fixed' -or
        $sampler.widgets_values[4] -ne 'er_sde' -or $sampler.widgets_values[5] -ne 'simple' -or
        $baseSteps.widgets_values[0] -ne 41 -or [double]$baseCfg.widgets_values[0] -ne 5.25 -or
        $turboSteps.widgets_values[0] -ne 8 -or [double]$turboCfg.widgets_values[0] -ne 1.0 -or
        $positive.widgets_values[0] -ne 'configured positive' -or $negative.widgets_values[0] -ne 'configured negative' -or
        [bool]$turboSwitch.widgets_values[0] -or $turboLoader.widgets_values[0] -ne 'anima-turbo-lora-v0.2.safetensors' -or
        [double]$turboLoader.widgets_values[1] -ne 1.0 -or $null -eq $managedCharacter -or
        [double]$managedCharacter.widgets_values[1] -ne 0.75 -or $null -eq $manualCharacter -or $null -eq $manualStyle -or
        [double]$manualCharacter.widgets_values[1] -ne 0 -or [double]$manualStyle.widgets_values[1] -ne 0 -or
        $workflowJson.Contains('install-only-style.safetensors') -or
        @($loraLoaders | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -like '*disabled*' }).Count -ne 0) {
        throw 'The managed workflow does not contain the configured base parameters.'
    }
    $standardInstance = @($workflow.nodes | Where-Object id -eq 90)[0]
    $standardProxies = @($standardInstance.properties.proxyWidgets | ForEach-Object { "{0}:{1}" -f $_[0], $_[1] })
    foreach ($expectedProxy in @(
        "$($manualCharacter.id):lora_name", "$($manualCharacter.id):strength_model",
        "$($manualStyle.id):lora_name", "$($manualStyle.id):strength_model"
    )) {
        if ($expectedProxy -notin $standardProxies) { throw "Manual LoRA proxy widget is missing: $expectedProxy" }
    }

    $hiresWorkflow = Get-Content -LiteralPath $hiresManaged -Raw -Encoding UTF8 | ConvertFrom-Json
    $hiresNodes = @($hiresWorkflow.definitions.subgraphs[0].nodes)
    $upscale = @($hiresNodes | Where-Object type -eq 'LatentUpscaleBy')[0]
    $refiner = @($hiresNodes | Where-Object { $_.PSObject.Properties.Name -contains 'title' -and [string]$_.title -eq 'Base hires refinement (Turbo excluded)' })[0]
    if ($null -eq $upscale -or $null -eq $refiner -or @($hiresNodes | Where-Object type -eq 'KSampler').Count -ne 2 -or
        $upscale.widgets_values[0] -ne 'bislerp' -or [double]$upscale.widgets_values[1] -ne 1.5 -or
        $refiner.widgets_values[2] -ne 20 -or [double]$refiner.widgets_values[3] -ne 4.5 -or
        $refiner.widgets_values[4] -ne 'er_sde' -or $refiner.widgets_values[5] -ne 'simple' -or
        [double]$refiner.widgets_values[6] -ne 0.35) {
        throw 'The managed hires workflow does not contain the configured Base refinement stage.'
    }
    $refinerModelInput = @($refiner.inputs | Where-Object name -eq 'model')[0]
    $refinerModelLink = @($hiresWorkflow.definitions.subgraphs[0].links | Where-Object id -eq $refinerModelInput.link)[0]
    $refinerModelSource = @($hiresNodes | Where-Object id -eq $refinerModelLink.origin_id)[0]
    if ($refinerModelSource.title -notlike 'Style LoRA*') {
        throw 'The hires refinement does not use the non-Turbo model and complete optional LoRA chain.'
    }
    $hiresInstance = @($hiresWorkflow.nodes | Where-Object id -eq 90)[0]
    $hiresProxies = @($hiresInstance.properties.proxyWidgets | ForEach-Object { "{0}:{1}" -f $_[0], $_[1] })
    foreach ($expectedWidget in @('scale_by', 'steps', 'cfg', 'denoise')) {
        if (-not @($hiresProxies | Where-Object { $_ -like "*:$expectedWidget" })) {
            throw "Hires proxy widget is missing: $expectedWidget"
        }
    }

    $webuiConfigPath = Join-Path $temporaryRoot 'webui-config.json'
    $webuiBackupPath = Join-Path $temporaryRoot 'records'
    $prepareOutput = & python $configurator prepare-webui $remoteConfigPath $webuiConfigPath $webuiBackupPath
    if ($LASTEXITCODE -ne 0 -or $prepareOutput -ne 'deferred' -or (Test-Path -LiteralPath $webuiConfigPath)) {
        throw 'A fresh Forge checkout must keep config.json absent until Forge writes its version marker.'
    }

    & python $configurator configure-webui $remoteConfigPath $webuiConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the simulated premature managed WebUI config.' }
    $prepareOutput = & python $configurator prepare-webui $remoteConfigPath $webuiConfigPath $webuiBackupPath
    if ($LASTEXITCODE -ne 0 -or $prepareOutput -notlike 'deferred:*' -or (Test-Path -LiteralPath $webuiConfigPath) -or
        -not (Test-Path -LiteralPath (Join-Path $webuiBackupPath 'webui-config.pre-first-start.json'))) {
        throw 'The premature managed WebUI config was not preserved and deferred for recovery.'
    }

    Save-JsonFile -Path $webuiConfigPath -Value ([ordered]@{
        VERSION_UID = 'PY313'
        custom_setting = 'keep-me'
        localization = 'None'
        disable_all_extensions = 'all'
        disabled_extensions = @('tag-autocomplete', 'keep-disabled')
    }) | Out-Null
    $prepareOutput = & python $configurator prepare-webui $remoteConfigPath $webuiConfigPath $webuiBackupPath
    if ($LASTEXITCODE -ne 0 -or $prepareOutput -ne 'configured') { throw 'prepare-webui failed for a versioned config.' }
    $webuiConfig = Get-Content -LiteralPath $webuiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($webuiConfig.VERSION_UID -ne 'PY313' -or $webuiConfig.custom_setting -ne 'keep-me' -or $webuiConfig.localization -ne 'zh_CN' -or
        $webuiConfig.disable_all_extensions -ne 'none' -or
        'tag-autocomplete' -in @($webuiConfig.disabled_extensions) -or
        'keep-disabled' -notin @($webuiConfig.disabled_extensions)) {
        throw 'WebUI configuration was not merged safely.'
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

Write-Host 'Managed Anima workflow and WebUI configuration checks passed.' -ForegroundColor Green
