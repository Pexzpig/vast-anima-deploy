[CmdletBinding()]
param(
    [ValidateSet('vast-comfy', 'base-image')]
    [string]$Profile,
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
$supportedGpus = @('RTX_4090', 'RTX_3090', 'RTX_A5000', 'A40', 'L40S')

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
    param([string[]]$AvailableGpus)

    for ($index = 0; $index -lt $AvailableGpus.Count; $index++) {
        Write-Host ("  {0}. {1}" -f ($index + 1), $AvailableGpus[$index])
    }
    Write-Host '直接回车表示全部；也可以输入逗号分隔的编号，例如 1,2,4。'

    while ($true) {
        $value = (Read-Host '选择允许的 GPU [全部]').Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $AvailableGpus }

        $indices = @()
        $valid = $true
        foreach ($part in ($value -split '[,，\s]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not [int]::TryParse($part, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $AvailableGpus.Count) {
                $valid = $false
                break
            }
            if ($indices -notcontains $parsed) { $indices += $parsed }
        }

        if ($valid -and $indices.Count -gt 0) {
            return @($indices | ForEach-Object { $AvailableGpus[$_ - 1] })
        }
        Write-Warning 'GPU 编号无效，请重新选择。'
    }
}

if (-not $UseDefaults) {
    Write-WizardPage -Page 1 -Total 4 -Title '选择部署配置'
    if (-not $Profile) {
        $profileChoice = Read-WizardChoice -Prompt '请选择配置' -Options @(
            'vastai/comfy 预装镜像（启动快）',
            'Vast 基础镜像（完整安装、便于深度定制）'
        ) -DefaultIndex 1
        $Profile = if ($profileChoice -eq 1) { 'vast-comfy' } else { 'base-image' }
    }
    Write-Host ("已选择：{0}" -f $Profile) -ForegroundColor Green

    Write-WizardPage -Page 2 -Total 4 -Title 'GPU 与预算'
    if (-not $GpuNames -or $GpuNames.Count -eq 0) { $GpuNames = Read-GpuSelection -AvailableGpus $supportedGpus }
    $MinGpuRamGb = Read-WizardNumber -Prompt '最低显存（GB）' -Default $MinGpuRamGb -Minimum 12 -Maximum 192
    $MaxHourlyUsd = Read-WizardNumber -Prompt '最高每小时价格（USD）' -Default $MaxHourlyUsd -Minimum 0.05 -Maximum 20

    Write-WizardPage -Page 3 -Total 4 -Title '主机质量与搜索范围'
    $MinReliability = Read-WizardNumber -Prompt '最低可靠度（0-1）' -Default $MinReliability -Minimum 0.80 -Maximum 1
    $MinDownloadMbps = Read-WizardNumber -Prompt '最低下载速度（Mbps）' -Default $MinDownloadMbps -Minimum 10 -Maximum 10000
    $MinCudaVersion = Read-WizardNumber -Prompt '最低 CUDA 版本' -Default $MinCudaVersion -Minimum 12.0 -Maximum 20
    $SearchLimit = [int](Read-WizardNumber -Prompt '最多读取多少个报价' -Default $SearchLimit -Minimum 5 -Maximum 200)

    Write-WizardPage -Page 4 -Total 4 -Title '持久卷'
    $volumeEnabled = Read-WizardYesNo -Prompt '启用持久卷保存模型和输出吗？' -Default $true
    $DisableVolume = -not $volumeEnabled
    if ($volumeEnabled) {
        $VolumeSizeGb = [int](Read-WizardNumber -Prompt '持久卷大小（GB）' -Default $VolumeSizeGb -Minimum 50 -Maximum 2048)
    }
} else {
    if (-not $Profile) { $Profile = 'vast-comfy' }
    if (-not $GpuNames -or $GpuNames.Count -eq 0) { $GpuNames = $supportedGpus }
}

$unknownGpus = @($GpuNames | Where-Object { $_ -notin $supportedGpus })
if ($unknownGpus.Count -gt 0) { throw "不支持的 GPU 名称：$($unknownGpus -join ', ')" }

$templatePath = if ($Profile -eq 'vast-comfy') { 'profiles/vast-comfy/config.psd1' } else { 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $templatePath
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
$config.Vast.Search.Query = $queryParts -join ' '
$config.Vast.Search.Limit = $SearchLimit
$config.Vast.Search.MaxHourlyUsd = $MaxHourlyUsd
$config.Vast.Volume.Enabled = -not [bool]$DisableVolume
$config.Vast.Volume.SizeGb = $VolumeSizeGb

$relativeConfigPath = "user-config/$Profile.json"
$resolvedConfigPath = Resolve-ProjectPath -Path $relativeConfigPath
if ((Test-Path -LiteralPath $resolvedConfigPath) -and -not $Force -and $UseDefaults) {
    throw "配置已存在：$resolvedConfigPath。若要覆盖，请使用 -Force。"
}

Save-JsonFile -Path $relativeConfigPath -Value $config | Out-Null
Save-JsonFile -Path 'user-config/launcher.json' -Value ([ordered]@{
    profile = $Profile
    config_path = $relativeConfigPath
    initialized_at = (Get-Date).ToUniversalTime().ToString('o')
}) | Out-Null

Write-Host ''
Write-Host '初始化完成。' -ForegroundColor Green
Write-Host "配置：$resolvedConfigPath"
Write-Host "GPU：$($GpuNames -join ', ')"
Write-Host ('价格上限：${0}/小时' -f $MaxHourlyUsd.ToString('0.####', $script:InvariantCulture))
Write-Host "持久卷：$(if ($config.Vast.Volume.Enabled) { "$VolumeSizeGb GB" } else { '关闭' })"

[pscustomobject]@{
    Profile = $Profile
    ConfigPath = $relativeConfigPath
    ResolvedConfigPath = $resolvedConfigPath
    Query = $config.Vast.Search.Query
}
