[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Deploy', 'Search', 'Status', 'Tunnel', 'Provision', 'Start', 'Stop', 'Destroy', 'RemoveVolume', 'Configure', 'Test', 'ConnectExisting')]
    [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$scriptsRoot = Join-Path $projectRoot 'scripts'
$configPath = Join-Path $projectRoot 'user-config\deployment.json'
. (Join-Path $scriptsRoot 'Common.ps1')

function Read-Confirmation {
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

function Update-DeploymentSshIdentity {
    param([string]$PrivateKeyPath)

    if (-not $PrivateKeyPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }
    $config = Get-DeployConfig -ConfigPath $configPath
    if ([string]$config.Vast.Ssh.IdentityFile -eq $PrivateKeyPath) { return }
    $config.Vast.Ssh.IdentityFile = $PrivateKeyPath
    Save-JsonFile -Path $configPath -Value $config | Out-Null
    Write-Host "当前部署配置已绑定 SSH 私钥：$PrivateKeyPath" -ForegroundColor Green
}

function Sync-StartupAccountInstances {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    Write-Host ''
    Write-Host '正在检查 Vast.ai 账户实例及状态...' -ForegroundColor Cyan
    $instances = @(Get-VastAccountInstances -Config $Config -TimeoutSeconds 30)
    $statusSummary = if ($instances.Count -eq 0) {
        '无活动实例'
    } else {
        @($instances |
            Group-Object { [string](Get-ObjectProperty -Object $_ -Names @('actual_status', 'status', 'cur_state') -Default 'unknown') } |
            Sort-Object Name |
            ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join '，'
    }
    Write-Host "账户实例检查完成：$($instances.Count) 个（$statusSummary）。" -ForegroundColor DarkCyan

    $statePath = Resolve-ProjectPath -Path ([string]$Config.Local.StatePath)
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Host '当前没有本地部署状态，不写入 deployment state。' -ForegroundColor DarkGray
        return $instances
    }

    $state = Get-DeploymentState -Config $Config
    $result = Sync-DeploymentInstanceState -Config $Config -State $state -AccountInstances $instances
    if (-not $result.Saved) {
        Write-Host '本地状态没有可对账的活动实例。' -ForegroundColor DarkGray
    } elseif ($result.Found) {
        Write-Host "实例 $($result.InstanceId) 状态已刷新：$($result.PreviousStatus) -> $($result.CurrentStatus)" -ForegroundColor Green
    } else {
        Write-Warning "实例 $($result.InstanceId) 已不在账户实例列表中，本地状态已更新为 destroyed。"
    }
    return $instances
}

function Get-LocalDeploymentSummary {
    param([hashtable]$Config)

    $statePath = Resolve-ProjectPath -Path ([string]$Config.Local.StatePath)
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{ Exists = $false; HasActiveResources = $false; CanResumeInstance = $false; CanContinueDeployment = $false; InstanceStatus = '未部署'; VolumeStatus = '无'; State = $null }
    }
    try {
        $state = Get-DeploymentState -Config $Config
        $hasActiveResources = Test-DeploymentStateHasActiveResources -State $state
        $canResumeInstance = Test-DeploymentStateCanResumeInstance -State $state
        $canContinueDeployment = Test-DeploymentStateCanContinueDeployment -State $state
        $instanceStatus = if ($state.instance_id) {
            [string]$state.instance_status
        } elseif ([string]$state.instance_status -in @('pending', 'create_failed', 'failed')) {
            '未创建（可重试）'
        } else {
            '无'
        }
        $volumeStatus = if ($state.volume_id) {
            [string]$state.volume_status
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

function Show-MainMenu {
    param([hashtable]$Config, $Summary)

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    $application = Get-DeploymentApplication -Config $Config -State $Summary.State
    $displayImage = if ($null -eq $Summary.State) { [string]$Config.Vast.Instance.Image } else { [string]$Summary.State.deployment_image }
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
    Write-Host ' 12. 连接账户已有脚本实例'
    Write-Host '  0. 退出'

    $mapping = @{
        '1' = 'Deploy'; '2' = 'Search'; '3' = 'Status'; '4' = 'Tunnel'
        '5' = 'Provision'; '6' = 'Start'; '7' = 'Stop'; '8' = 'Configure'
        '9' = 'Test'; '10' = 'Destroy'; '11' = 'RemoveVolume'; '12' = 'ConnectExisting'
        '0' = 'Exit'
    }
    while ($true) {
        $choice = (Read-Host '请选择操作').Trim()
        if ($mapping.ContainsKey($choice)) { return $mapping[$choice] }
        Write-Warning '请输入菜单中的编号。'
    }
}

function Invoke-MainOperation {
    param([string]$Name, [hashtable]$Config)

    $summary = Get-LocalDeploymentSummary -Config $Config
    switch ($Name) {
        'Deploy' {
            if ($summary.Exists -and $summary.HasActiveResources -and
                -not $summary.CanResumeInstance -and
                -not $summary.CanContinueDeployment) {
                throw '当前配置仍跟踪远端实例或持久卷。请先查看状态并处理已有资源，避免重复计费。'
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
            & (Join-Path $scriptsRoot 'Initialize-DeploymentConfig.ps1') -Force | Out-Host
        }
        'Test' {
            & (Join-Path $scriptsRoot 'Test-Configuration.ps1') -ConfigPath $configPath
        }
        'Destroy' {
            if (-not $summary.Exists -or -not $summary.State.instance_id -or $summary.State.instance_status -eq 'destroyed') { throw '没有可销毁的活动实例。' }
            $instanceId = $summary.State.instance_id
            if (-not (Read-Confirmation -Prompt "确认永久销毁实例 $instanceId 吗？")) {
                Write-Host '销毁已取消。'; return
            }
            & (Join-Path $scriptsRoot 'Destroy-VastInstance.ps1') -ConfigPath $configPath -Force
        }
        'RemoveVolume' {
            if (-not $summary.Exists -or -not $summary.State.volume_id -or $summary.VolumeStatus -eq 'deleted') {
                throw '没有可删除的持久卷。'
            }
            $volumeId = $summary.State.volume_id
            if (-not (Read-Confirmation -Prompt "确认永久删除持久卷 $volumeId 及其中模型和输出吗？")) {
                Write-Host '删除已取消。'; return
            }
            & (Join-Path $scriptsRoot 'Remove-VastVolume.ps1') -ConfigPath $configPath -Force
        }
        'ConnectExisting' {
            & (Join-Path $scriptsRoot 'Connect-VastExistingInstance.ps1') -ConfigPath $configPath
        }
        default { throw "未知操作：$Name" }
    }
}

$firstRun = -not (Test-Path -LiteralPath $configPath -PathType Leaf)
$environmentConfig = if ($firstRun) { Join-Path $projectRoot 'config.psd1' } else { $configPath }
$environmentStatus = & (Join-Path $scriptsRoot 'Initialize-Environment.ps1') -ConfigPath $environmentConfig -PassThru

if ($firstRun) {
    Write-Host ''
    Write-Host '这是首次运行。接下来通过终端向导初始化搜索和部署参数。' -ForegroundColor Cyan
    & (Join-Path $scriptsRoot 'Initialize-DeploymentConfig.ps1') | Out-Host
    Update-DeploymentSshIdentity -PrivateKeyPath $environmentStatus.SshPrivateKey
    if ($Action -eq 'Configure') { $Action = 'Menu' }
    if ($Action -eq 'Menu' -and (Read-Confirmation -Prompt '初始化已完成，现在搜索报价并开始部署吗？')) {
        $Action = 'Deploy'
    }
} else {
    Update-DeploymentSshIdentity -PrivateKeyPath $environmentStatus.SshPrivateKey
}

$config = Get-DeployConfig -ConfigPath $configPath
$startupAccountInstances = @(Sync-StartupAccountInstances -Config $config)

if ($Action -ne 'Menu') {
    Invoke-MainOperation -Name $Action -Config $config
    exit 0
}

while ($true) {
    Update-DeploymentSshIdentity -PrivateKeyPath $environmentStatus.SshPrivateKey
    $config = Get-DeployConfig -ConfigPath $configPath
    $summary = Get-LocalDeploymentSummary -Config $config
    $selectedAction = Show-MainMenu -Config $config -Summary $summary
    if ($selectedAction -eq 'Exit') { break }
    try {
        Invoke-MainOperation -Name $selectedAction -Config $config
    } catch {
        Write-Host ''
        Write-Host ("操作失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}
