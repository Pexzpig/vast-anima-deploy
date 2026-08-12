[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Deploy', 'Search', 'Status', 'Tunnel', 'Provision', 'Start', 'Stop', 'Destroy', 'RemoveVolume', 'Configure', 'Test')]
    [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$scriptsRoot = Join-Path $projectRoot 'scripts'
. (Join-Path $scriptsRoot 'Common.ps1')

function Read-LauncherYesNo {
    param([string]$Prompt, [bool]$Default = $false)

    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('y', 'yes', '是', '好')) { return $true }
        if ($answer -in @('n', 'no', '否', '不')) { return $false }
        Write-Warning '请输入 y 或 n。'
    }
}

function Get-LauncherSelection {
    $path = Resolve-ProjectPath -Path 'user-config/launcher.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Update-LauncherSshIdentity {
    param($Selection, [string]$PrivateKeyPath)

    if ($null -eq $Selection -or -not $PrivateKeyPath) { return }
    $configPath = Resolve-ProjectPath -Path ([string]$Selection.config_path)
    if ([System.IO.Path]::GetExtension($configPath) -ine '.json') { return }
    $selectedConfig = Get-DeployConfig -ConfigPath $configPath
    if ([string]$selectedConfig.Vast.Ssh.IdentityFile -eq $PrivateKeyPath) { return }
    $selectedConfig.Vast.Ssh.IdentityFile = $PrivateKeyPath
    Save-JsonFile -Path $configPath -Value $selectedConfig | Out-Null
    Write-Host "当前部署配置已绑定 SSH 私钥：$PrivateKeyPath" -ForegroundColor Green
}

function Initialize-SingleDeploymentConfiguration {
    $canonicalRelativePath = 'user-config/deployment.json'
    $canonicalPath = Resolve-ProjectPath -Path $canonicalRelativePath
    $legacySelection = Get-LauncherSelection
    $legacyConfig = $null
    $legacyConfigPath = $null

    if ($null -ne $legacySelection -and $legacySelection.config_path) {
        $legacyConfigPath = Resolve-ProjectPath -Path ([string]$legacySelection.config_path)
        if (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) {
            $legacyConfig = Get-DeployConfig -ConfigPath $legacyConfigPath
        }
    }

    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf) -and $null -ne $legacyConfig) {
        Write-Host '检测到旧版多配置结构，正在迁移为单一 PyTorch 部署配置...' -ForegroundColor Cyan
        $config = Get-DeployConfig -ConfigPath 'config.psd1'

        $config.Vast.Search = $legacyConfig.Vast.Search
        $config.Vast.Search.LastSearchPath = 'state/last-search.json'
        $config.Vast.Volume.Enabled = [bool]$legacyConfig.Vast.Volume.Enabled
        $config.Vast.Volume.SizeGb = [int]$legacyConfig.Vast.Volume.SizeGb
        $config.Vast.Ssh.IdentityFile = [string]$legacyConfig.Vast.Ssh.IdentityFile
        $config.Secrets = $legacyConfig.Secrets
        $config.Codex = $legacyConfig.Codex
        $config.Application.DefaultType = 'comfyui'
        Save-JsonFile -Path $canonicalRelativePath -Value $config | Out-Null
    }

    if ((Test-Path -LiteralPath $canonicalPath -PathType Leaf) -and $null -ne $legacyConfig) {
        $config = Get-DeployConfig -ConfigPath $canonicalPath
        $legacyStatePath = Resolve-ProjectPath -Path ([string]$legacyConfig.Local.StatePath)
        $canonicalStatePath = Resolve-ProjectPath -Path ([string]$config.Local.StatePath)
        if ($legacyStatePath -ne $canonicalStatePath -and
            (Test-Path -LiteralPath $legacyStatePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $canonicalStatePath -PathType Leaf)) {
            $legacyState = Get-Content -LiteralPath $legacyStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($legacyState.PSObject.Properties.Name -notcontains 'application_type') {
                $legacyState | Add-Member -NotePropertyName application_type -NotePropertyValue 'comfyui'
            }
            if ($legacyState.PSObject.Properties.Name -notcontains 'deployment_image') {
                $legacyState | Add-Member -NotePropertyName deployment_image -NotePropertyValue ([string]$legacyConfig.Vast.Instance.Image)
            }
            if ($legacyState.PSObject.Properties.Name -contains 'schema_version') {
                $legacyState.schema_version = 2
            } else {
                $legacyState | Add-Member -NotePropertyName schema_version -NotePropertyValue 2
            }
            Save-JsonFile -Path ([string]$config.Local.StatePath) -Value $legacyState | Out-Null
            Write-Host "已保留现有实例/卷状态：$canonicalStatePath" -ForegroundColor Yellow
        }
    }

    if (Test-Path -LiteralPath $canonicalPath -PathType Leaf) {
        Save-JsonFile -Path 'user-config/launcher.json' -Value ([ordered]@{
            deployment = 'pytorch-ui'
            config_path = $canonicalRelativePath
            selected_at = (Get-Date).ToUniversalTime().ToString('o')
        }) | Out-Null
        return Get-LauncherSelection
    }
    return $null
}

function Get-LocalDeploymentSummary {
    param([hashtable]$Config)

    $statePath = Resolve-ProjectPath -Path ([string]$Config.Local.StatePath)
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{ Exists = $false; HasActiveResources = $false; CanResumeInstance = $false; CanContinueDeployment = $false; InstanceStatus = '未部署'; VolumeStatus = '无'; State = $null }
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasActiveResources = Test-DeploymentStateHasActiveResources -State $state
        $canResumeInstance = Test-DeploymentStateCanResumeInstance -State $state
        $canContinueDeployment = Test-DeploymentStateCanContinueDeployment -State $state
        $instanceStatus = if ($state.instance_id) {
            if ($state.instance_status) { [string]$state.instance_status } else { 'unknown' }
        } elseif ([string]$state.instance_status -in @('pending', 'create_failed', 'failed')) {
            '未创建（可重试）'
        } else {
            '无'
        }
        $volumeStatus = if ($state.volume_id) {
            if ($state.volume_status) { [string]$state.volume_status } else { 'created' }
        } elseif ([string]$state.volume_status -eq 'disabled') {
            '未启用'
        } elseif ([string]$state.volume_status -in @('pending', 'create_failed', 'failed')) {
            '未创建（可重试）'
        } else {
            '无'
        }
        return [pscustomobject]@{
            Exists = $true
            HasActiveResources = $hasActiveResources
            CanResumeInstance = $canResumeInstance
            CanContinueDeployment = $canContinueDeployment
            InstanceStatus = $instanceStatus
            VolumeStatus = $volumeStatus
            State = $state
        }
    } catch {
        throw "无法读取部署状态 $statePath：$($_.Exception.Message)"
    }
}

function Show-LauncherMenu {
    param($Selection, [hashtable]$Config, $Summary)

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    $application = Get-DeploymentApplication -Config $Config -State $Summary.State
    $displayImage = [string](Get-ObjectProperty -Object $Summary.State -Names @('deployment_image') -Default $Config.Vast.Instance.Image)
    Write-Host ' Anima · Vast.ai PyTorch 自动部署' -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host "远端应用：$($application.DisplayName)"
    Write-Host "镜像：$displayImage"
    Write-Host "实例：$($Summary.InstanceStatus)    持久卷：$($Summary.VolumeStatus)"
    Write-Host ''
    Write-Host '  1. 自动搜索并部署'
    Write-Host '  2. 查看符合条件的报价'
    Write-Host '  3. 查看部署状态'
    Write-Host '  4. 打开应用 SSH 隧道'
    Write-Host '  5. 重新执行配置部署'
    Write-Host '  6. 启动实例'
    Write-Host '  7. 停止实例'
    Write-Host '  8. 修改搜索参数'
    Write-Host '  9. 检查配置'
    Write-Host ' 10. 销毁实例'
    Write-Host ' 11. 永久删除持久卷'
    Write-Host '  0. 退出'

    $mapping = @{
        '1' = 'Deploy'; '2' = 'Search'; '3' = 'Status'; '4' = 'Tunnel'
        '5' = 'Provision'; '6' = 'Start'; '7' = 'Stop'; '8' = 'Configure'
        '9' = 'Test'; '10' = 'Destroy'; '11' = 'RemoveVolume'
        '0' = 'Exit'
    }
    while ($true) {
        $choice = (Read-Host '请选择操作').Trim()
        if ($mapping.ContainsKey($choice)) { return $mapping[$choice] }
        Write-Warning '请输入菜单中的编号。'
    }
}

function Invoke-LauncherOperation {
    param([string]$Name, $Selection, [hashtable]$Config)

    $configPath = Resolve-ProjectPath -Path ([string]$Selection.config_path)
    $summary = Get-LocalDeploymentSummary -Config $Config
    switch ($Name) {
        'Deploy' {
            if ($summary.Exists -and $summary.HasActiveResources -and
                -not $summary.CanResumeInstance -and
                -not $summary.CanContinueDeployment) {
                throw "当前配置仍跟踪远端实例或持久卷。请先查看状态并处理已有资源，避免重复计费。"
            }
            & (Join-Path $scriptsRoot 'Test-Configuration.ps1') -ConfigPath $configPath
            Write-Host ''
            if ($summary.CanContinueDeployment) {
                Write-Host "将继续实例 $($summary.State.instance_id) 的部署，不会重新创建实例或持久卷。" -ForegroundColor Yellow
            } elseif ($summary.CanResumeInstance) {
                Write-Host "将复用已创建的持久卷 $($summary.State.volume_id)，只重试创建实例，不会重复创建卷。" -ForegroundColor Yellow
            } else {
                Write-Host '接下来先选择持久卷或实例磁盘，再实时搜索符合 GPU、预算及所选存储条件的报价。' -ForegroundColor Cyan
            }
            & (Join-Path $scriptsRoot 'Deploy-Example.ps1') -ConfigPath $configPath
        }
        'Search' {
            & (Join-Path $scriptsRoot 'Search-VastOffers.ps1') -ConfigPath $configPath | Out-Host
        }
        'Status' {
            if (-not $summary.Exists) { Write-Host '当前配置尚未部署。' -ForegroundColor Yellow; return }
            & (Join-Path $scriptsRoot 'Get-DeploymentStatus.ps1') -ConfigPath $configPath
        }
        'Tunnel' {
            if (-not $summary.Exists -or $summary.InstanceStatus -ne 'running') { throw '只有运行中的实例才能打开隧道。' }
            & (Join-Path $scriptsRoot 'Open-AppTunnel.ps1') -ConfigPath $configPath
        }
        'Provision' {
            if (-not $summary.Exists -or $summary.InstanceStatus -ne 'running') { throw '只有运行中的实例才能执行配置部署。' }
            & (Join-Path $scriptsRoot 'Provision-Instance.ps1') -ConfigPath $configPath
        }
        'Start' {
            if (-not $summary.Exists) { throw '当前配置尚未部署。' }
            & (Join-Path $scriptsRoot 'Start-VastInstance.ps1') -ConfigPath $configPath
        }
        'Stop' {
            if (-not $summary.Exists) { throw '当前配置尚未部署。' }
            & (Join-Path $scriptsRoot 'Stop-VastInstance.ps1') -ConfigPath $configPath
        }
        'Configure' {
            & (Join-Path $scriptsRoot 'Initialize-SearchProfile.ps1') -Force | Out-Host
        }
        'Test' {
            & (Join-Path $scriptsRoot 'Test-Configuration.ps1') -ConfigPath $configPath
        }
        'Destroy' {
            if (-not $summary.Exists -or -not $summary.State.instance_id -or $summary.State.instance_status -eq 'destroyed') { throw '没有可销毁的活动实例。' }
            $instanceId = $summary.State.instance_id
            if (-not (Read-LauncherYesNo -Prompt "确认永久销毁实例 $instanceId 吗？")) {
                Write-Host '销毁已取消。'; return
            }
            & (Join-Path $scriptsRoot 'Destroy-VastInstance.ps1') -ConfigPath $configPath -Force
        }
        'RemoveVolume' {
            if (-not $summary.Exists -or -not $summary.State.volume_id -or $summary.VolumeStatus -eq 'deleted') {
                throw '没有可删除的持久卷。'
            }
            $volumeId = $summary.State.volume_id
            if (-not (Read-LauncherYesNo -Prompt "确认永久删除持久卷 $volumeId 及其中模型和输出吗？")) {
                Write-Host '删除已取消。'; return
            }
            & (Join-Path $scriptsRoot 'Remove-VastVolume.ps1') -ConfigPath $configPath -Force
        }
        default { throw "未知操作：$Name" }
    }
}

$selection = Initialize-SingleDeploymentConfiguration
$firstRun = ($null -eq $selection)
$environmentConfig = if ($firstRun) { Join-Path $projectRoot 'config.psd1' } else { Resolve-ProjectPath -Path ([string]$selection.config_path) }
$environmentStatus = & (Join-Path $scriptsRoot 'Initialize-Environment.ps1') -ConfigPath $environmentConfig -PassThru
if (-not $firstRun) {
    Update-LauncherSshIdentity -Selection $selection -PrivateKeyPath $environmentStatus.SshPrivateKey
}

if ($firstRun) {
    Write-Host ''
    Write-Host '这是首次运行。接下来通过终端向导初始化搜索和部署参数。' -ForegroundColor Cyan
    & (Join-Path $scriptsRoot 'Initialize-SearchProfile.ps1') | Out-Host
    $selection = Get-LauncherSelection
    Update-LauncherSshIdentity -Selection $selection -PrivateKeyPath $environmentStatus.SshPrivateKey
    if ($Action -eq 'Configure') { $Action = 'Menu' }
    if ($Action -eq 'Menu' -and (Read-LauncherYesNo -Prompt '初始化已完成，现在搜索报价并开始部署吗？')) {
        $Action = 'Deploy'
    }
}

if ($Action -ne 'Menu') {
    $selection = Get-LauncherSelection
    $config = Get-DeployConfig -ConfigPath ([string]$selection.config_path)
    Invoke-LauncherOperation -Name $Action -Selection $selection -Config $config
    exit 0
}

while ($true) {
    $selection = Get-LauncherSelection
    Update-LauncherSshIdentity -Selection $selection -PrivateKeyPath $environmentStatus.SshPrivateKey
    $config = Get-DeployConfig -ConfigPath ([string]$selection.config_path)
    $summary = Get-LocalDeploymentSummary -Config $config
    $selectedAction = Show-LauncherMenu -Selection $selection -Config $config -Summary $summary
    if ($selectedAction -eq 'Exit') { break }
    try {
        Invoke-LauncherOperation -Name $selectedAction -Selection $selection -Config $config
    } catch {
        Write-Host ''
        Write-Host ("操作失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}
