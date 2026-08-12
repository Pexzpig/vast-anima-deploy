[CmdletBinding()]
param(
    [ValidateSet('ComfyUI', 'WebUI')]
    [string]$ApplicationType,
    [string[]]$GpuNames,
    [double]$MinGpuRamGb = 16,
    [double]$MaxHourlyUsd = 0.80,
    [double]$MinReliability = 0.98,
    [double]$MinDownloadMbps = 200,
    [double]$MinCudaVersion = 12.8,
    [int]$SearchLimit = 25,
    [int]$VolumeSizeGb = 80,
    [switch]$DisableVolume,
    [switch]$UseDefaults,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$gpuGroups = [ordered]@{
    Consumer = [ordered]@{
        Label = 'GeForce RTX（30/40/50 系列）'
        Gpus = @(
            'RTX_3090', 'RTX_3090_Ti',
            'RTX_4060_Ti', 'RTX_4070', 'RTX_4070S', 'RTX_4070_Ti', 'RTX_4070S_Ti',
            'RTX_4080', 'RTX_4080S', 'RTX_4090', 'RTX_4090D',
            'RTX_5060_Ti', 'RTX_5070', 'RTX_5070_Ti', 'RTX_5080', 'RTX_5090'
        )
    }
    AdaPro = [ordered]@{
        Label = 'RTX Ada / RTX PRO 工作站系列'
        Gpus = @(
            'RTX_2000Ada', 'RTX_4000Ada', 'RTX_4500Ada', 'RTX_5000Ada', 'RTX_5880Ada', 'RTX_6000Ada',
            'RTX_PRO_4000', 'RTX_PRO_4500', 'RTX_PRO_5000', 'RTX_PRO_6000_S', 'RTX_PRO_6000_WS'
        )
    }
    RtxA = [ordered]@{
        Label = 'RTX A 工作站系列'
        Gpus = @('RTX_A2000', 'RTX_A4000', 'RTX_A4500', 'RTX_A5000', 'RTX_A6000')
    }
    DataCenter = [ordered]@{
        Label = '现代数据中心系列'
        Gpus = @(
            'A10', 'A10g', 'A40', 'L4', 'L40', 'L40S',
            'A100_PCIE', 'A100_SXM4', 'A100X', 'A800_PCIE',
            'H100_PCIE', 'H100_SXM', 'H100_NVL', 'H200', 'H200_NVL', 'B200'
        )
    }
}
$supportedGpus = @($gpuGroups.Keys | ForEach-Object { $gpuGroups[$_].Gpus } | Select-Object -Unique)
$recommendedGpus = @(
    'RTX_3090', 'RTX_3090_Ti', 'RTX_4080', 'RTX_4080S', 'RTX_4090', 'RTX_4090D', 'RTX_5080', 'RTX_5090',
    'RTX_4000Ada', 'RTX_4500Ada', 'RTX_5000Ada', 'RTX_5880Ada', 'RTX_6000Ada',
    'RTX_PRO_4000', 'RTX_PRO_4500', 'RTX_PRO_5000', 'RTX_PRO_6000_S', 'RTX_PRO_6000_WS',
    'RTX_A4000', 'RTX_A4500', 'RTX_A5000', 'RTX_A6000',
    'A10', 'A10g', 'A40', 'L4', 'L40', 'L40S',
    'A100_PCIE', 'A100_SXM4', 'A100X', 'A800_PCIE',
    'H100_PCIE', 'H100_SXM', 'H100_NVL', 'H200', 'H200_NVL', 'B200'
)

$relativeConfigPath = 'user-config/deployment.json'
$resolvedConfigPath = Resolve-ProjectPath -Path $relativeConfigPath
$configExists = Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf
$config = if ($configExists) {
    Get-DeployConfig -ConfigPath $resolvedConfigPath
} else {
    Get-DeployConfig -ConfigPath 'config.psd1'
}
$defaultApplicationType = if ([string]$config.Application.DefaultType -eq 'webui') { 'WebUI' } else { 'ComfyUI' }
$defaultGpuNames = $recommendedGpus

if ($configExists -and -not $UseDefaults) {
    $storedQuery = [string]$config.Vast.Search.Query
    if (-not $PSBoundParameters.ContainsKey('GpuNames') -and $storedQuery -match 'gpu_name\s+in\s+\[([^\]]+)\]') {
        $defaultGpuNames = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if (-not $PSBoundParameters.ContainsKey('MinGpuRamGb') -and $storedQuery -match 'gpu_ram>=([0-9.]+)') { $MinGpuRamGb = [double]::Parse($Matches[1], $script:InvariantCulture) }
    if (-not $PSBoundParameters.ContainsKey('MinReliability') -and $storedQuery -match 'reliability>=([0-9.]+)') { $MinReliability = [double]::Parse($Matches[1], $script:InvariantCulture) }
    if (-not $PSBoundParameters.ContainsKey('MinDownloadMbps') -and $storedQuery -match 'inet_down>=([0-9.]+)') { $MinDownloadMbps = [double]::Parse($Matches[1], $script:InvariantCulture) }
    if (-not $PSBoundParameters.ContainsKey('MinCudaVersion') -and $storedQuery -match 'cuda_vers>=([0-9.]+)') { $MinCudaVersion = [double]::Parse($Matches[1], $script:InvariantCulture) }
    if (-not $PSBoundParameters.ContainsKey('MaxHourlyUsd')) { $MaxHourlyUsd = [double]$config.Vast.Search.MaxHourlyUsd }
    if (-not $PSBoundParameters.ContainsKey('SearchLimit')) { $SearchLimit = [int]$config.Vast.Search.Limit }
    if (-not $PSBoundParameters.ContainsKey('VolumeSizeGb')) { $VolumeSizeGb = [int]$config.Vast.Volume.SizeGb }
    if (-not $PSBoundParameters.ContainsKey('DisableVolume')) { $DisableVolume = -not [bool]$config.Vast.Volume.Enabled }
}

function Write-WizardPage {
    param([int]$Page, [int]$Total, [string]$Title)

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host (" Anima / Vast.ai 初始化向导  [{0}/{1}]  {2}" -f $Page, $Total, $Title) -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
}

function Read-WizardChoice {
    param([string]$Prompt, [string[]]$Options, [int]$DefaultIndex = 1)

    for ($index = 0; $index -lt $Options.Count; $index++) {
        $suffix = if (($index + 1) -eq $DefaultIndex) { '（推荐/默认）' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), $Options[$index], $suffix)
    }

    while ($true) {
        $value = (Read-Host ("$Prompt [$DefaultIndex]")).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultIndex }

        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Options.Count) {
            return $parsed
        }
        Write-Warning "请输入 1 到 $($Options.Count) 之间的编号。"
    }
}

function Read-WizardNumber {
    param([string]$Prompt, [double]$Default, [double]$Minimum, [double]$Maximum)

    while ($true) {
        $defaultText = $Default.ToString('0.####', $script:InvariantCulture)
        $value = (Read-Host ("$Prompt [$defaultText]")).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }

        $parsed = 0.0
        $valid = [double]::TryParse(
            $value,
            [System.Globalization.NumberStyles]::Float,
            $script:InvariantCulture,
            [ref]$parsed
        )
        if (-not $valid) { $valid = [double]::TryParse($value, [ref]$parsed) }
        if ($valid -and $parsed -ge $Minimum -and $parsed -le $Maximum) { return $parsed }
        Write-Warning ("请输入 {0} 到 {1} 之间的数字。" -f $Minimum, $Maximum)
    }
}

function Read-WizardYesNo {
    param([string]$Prompt, [bool]$Default = $true)

    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = (Read-Host ("$Prompt [$hint]")).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        if ($value -in @('y', 'yes', '是', '好')) { return $true }
        if ($value -in @('n', 'no', '否', '不')) { return $false }
        Write-Warning '请输入 y 或 n。'
    }
}

function Read-GpuSelection {
    param(
        [System.Collections.IDictionary]$Groups,
        [string[]]$Recommended,
        [string[]]$AvailableGpus
    )

    $presets = @(
        [pscustomobject]@{ Label = '当前/推荐的型号范围'; Gpus = $Recommended }
        [pscustomobject]@{ Label = $Groups.Consumer.Label; Gpus = $Groups.Consumer.Gpus }
        [pscustomobject]@{ Label = $Groups.AdaPro.Label; Gpus = $Groups.AdaPro.Gpus }
        [pscustomobject]@{ Label = $Groups.RtxA.Label; Gpus = $Groups.RtxA.Gpus }
        [pscustomobject]@{ Label = $Groups.DataCenter.Label; Gpus = $Groups.DataCenter.Gpus }
        [pscustomobject]@{ Label = '全部支持型号'; Gpus = $AvailableGpus }
    )
    for ($index = 0; $index -lt $presets.Count; $index++) {
        $suffix = if ($index -eq 0) { '（推荐/默认）' } else { '' }
        Write-Host ("  {0}. {1}（{2} 种）{3}" -f ($index + 1), $presets[$index].Label, @($presets[$index].Gpus).Count, $suffix)
    }
    Write-Host '  7. 按具体型号逐项选择'
    Write-Host '可组合多个分类，例如 2,3,5；直接回车使用推荐范围。'

    while ($true) {
        $value = (Read-Host '选择 GPU 分类 [1]').Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Recommended }

        $indices = @()
        $valid = $true
        foreach ($part in ($value -split '[,，\s]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not [int]::TryParse($part, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 7) {
                $valid = $false
                break
            }
            if ($indices -notcontains $parsed) { $indices += $parsed }
        }
        if (-not $valid -or $indices.Count -eq 0) {
            Write-Warning 'GPU 分类编号无效，请重新选择。'
            continue
        }

        if ($indices -contains 7) {
            if ($indices.Count -ne 1) {
                Write-Warning '逐项选择不能与分类编号组合。'
                continue
            }
            for ($index = 0; $index -lt $AvailableGpus.Count; $index++) {
                Write-Host ("  {0}. {1}" -f ($index + 1), $AvailableGpus[$index])
            }
            while ($true) {
                $modelValue = (Read-Host '输入具体型号编号（逗号分隔）').Trim()
                $modelIndices = @()
                $modelValid = $true
                foreach ($part in ($modelValue -split '[,，\s]+' | Where-Object { $_ })) {
                    $parsed = 0
                    if (-not [int]::TryParse($part, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $AvailableGpus.Count) {
                        $modelValid = $false
                        break
                    }
                    if ($modelIndices -notcontains $parsed) { $modelIndices += $parsed }
                }
                if ($modelValid -and $modelIndices.Count -gt 0) {
                    return @($modelIndices | ForEach-Object { $AvailableGpus[$_ - 1] })
                }
                Write-Warning '具体型号编号无效，请重新选择。'
            }
        }

        $selected = @()
        foreach ($index in $indices) {
            foreach ($gpu in @($presets[$index - 1].Gpus)) {
                if ($selected -notcontains $gpu) { $selected += $gpu }
            }
        }
        return $selected
    }
}

if (-not $UseDefaults) {
    Write-WizardPage -Page 1 -Total 4 -Title '默认远端应用'
    if (-not $ApplicationType) {
        $defaultApplicationIndex = if ($defaultApplicationType -eq 'WebUI') { 2 } else { 1 }
        $applicationChoice = Read-WizardChoice -Prompt '请选择默认应用' -Options @(
            'ComfyUI + Anima workflow',
            'Forge Classic WebUI（neo 分支）'
        ) -DefaultIndex $defaultApplicationIndex
        $ApplicationType = if ($applicationChoice -eq 1) { 'ComfyUI' } else { 'WebUI' }
    }
    Write-Host ("默认应用：{0}" -f $ApplicationType) -ForegroundColor Green

    Write-WizardPage -Page 2 -Total 4 -Title 'GPU 与预算'
    if (-not $GpuNames -or $GpuNames.Count -eq 0) {
        $GpuNames = Read-GpuSelection -Groups $gpuGroups -Recommended $defaultGpuNames -AvailableGpus $supportedGpus
    }
    $MinGpuRamGb = Read-WizardNumber -Prompt '最低显存（GB）' -Default $MinGpuRamGb -Minimum 12 -Maximum 192
    $MaxHourlyUsd = Read-WizardNumber -Prompt '最高每小时价格（USD）' -Default $MaxHourlyUsd -Minimum 0.05 -Maximum 20

    Write-WizardPage -Page 3 -Total 4 -Title '主机质量与搜索范围'
    $MinReliability = Read-WizardNumber -Prompt '最低可靠度（0-1）' -Default $MinReliability -Minimum 0.80 -Maximum 1
    $MinDownloadMbps = Read-WizardNumber -Prompt '最低下载速度（Mbps）' -Default $MinDownloadMbps -Minimum 10 -Maximum 10000
    $MinCudaVersion = Read-WizardNumber -Prompt '最低 CUDA 版本' -Default $MinCudaVersion -Minimum 12.0 -Maximum 20
    $SearchLimit = [int](Read-WizardNumber -Prompt '最多读取多少个报价' -Default $SearchLimit -Minimum 5 -Maximum 200)

    Write-WizardPage -Page 4 -Total 4 -Title '持久卷'
    $volumeEnabled = Read-WizardYesNo -Prompt '启用持久卷保存模型和输出吗？' -Default (-not [bool]$DisableVolume)
    $DisableVolume = -not $volumeEnabled
    if ($volumeEnabled) {
        $VolumeSizeGb = [int](Read-WizardNumber -Prompt '持久卷大小（GB）' -Default $VolumeSizeGb -Minimum 50 -Maximum 2048)
    }
} else {
    if (-not $ApplicationType) { $ApplicationType = $defaultApplicationType }
    if (-not $GpuNames -or $GpuNames.Count -eq 0) { $GpuNames = $recommendedGpus }
}

$unknownGpus = @($GpuNames | Where-Object { $_ -notin $supportedGpus })
if ($unknownGpus.Count -gt 0) { throw "不支持的 GPU 名称：$($unknownGpus -join ', ')" }

$queryParts = @(
    ('gpu_name in [{0}]' -f ($GpuNames -join ','))
    'num_gpus=1'
    ('gpu_ram>={0}' -f $MinGpuRamGb.ToString('0.####', $script:InvariantCulture))
    'verified=true'
    'rentable=true'
    'rented=false'
    'direct_port_count>=1'
    ('reliability>={0}' -f $MinReliability.ToString('0.####', $script:InvariantCulture))
    ('inet_down>={0}' -f $MinDownloadMbps.ToString('0.####', $script:InvariantCulture))
    ('cuda_vers>={0}' -f $MinCudaVersion.ToString('0.####', $script:InvariantCulture))
    ('dph_total<={0}' -f $MaxHourlyUsd.ToString('0.####', $script:InvariantCulture))
)
$config = Set-DeploymentSearchPreferences `
    -Config $config `
    -Query ($queryParts -join ' ') `
    -SearchLimit $SearchLimit `
    -MaxHourlyUsd $MaxHourlyUsd `
    -VolumeEnabled (-not [bool]$DisableVolume) `
    -VolumeSizeGb $VolumeSizeGb `
    -ApplicationType $ApplicationType.ToLowerInvariant()

if ((Test-Path -LiteralPath $resolvedConfigPath) -and -not $Force -and $UseDefaults) {
    throw "配置已存在：$resolvedConfigPath。若要覆盖，请使用 -Force。"
}

Save-JsonFile -Path $relativeConfigPath -Value $config | Out-Null

Write-Host ''
Write-Host '初始化完成。' -ForegroundColor Green
Write-Host "配置：$resolvedConfigPath"
Write-Host "默认应用：$ApplicationType"
Write-Host "GPU：$($GpuNames -join ', ')"
Write-Host ('价格上限：${0}/小时' -f $MaxHourlyUsd.ToString('0.####', $script:InvariantCulture))
Write-Host "持久卷：$(if ($config.Vast.Volume.Enabled) { "$VolumeSizeGb GB" } else { '关闭' })"

[pscustomobject]@{
    ApplicationType = $ApplicationType
    ConfigPath = $relativeConfigPath
    ResolvedConfigPath = $resolvedConfigPath
    Query = $config.Vast.Search.Query
}
