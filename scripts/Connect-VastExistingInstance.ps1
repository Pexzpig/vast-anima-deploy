[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int64]$InstanceId = 0,
    [ValidateSet('Prompt', 'Shell', 'Tunnel')]
    [string]$Mode = 'Prompt',
    [switch]$StartIfStopped
)

. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$config = Add-CurrentFeatureConfigurationDefaults `
    -Config (Get-DeployConfig -ConfigPath $ConfigPath) `
    -Template (Get-DeployConfig -ConfigPath 'config.psd1')
Assert-CommandExists -Name 'ssh'

function Read-MenuNumber {
    param([string]$Prompt, [int]$Minimum, [int]$Maximum)
    while ($true) {
        $text = (Read-Host $Prompt).Trim()
        $value = 0
        if ([int]::TryParse($text, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) { return $value }
        Write-Warning "请输入 $Minimum 到 $Maximum 之间的编号。"
    }
}

function Read-StartConfirmation {
    param([string]$Status)
    $answer = (Read-Host "实例当前为 '$Status'。启动后将恢复 GPU 计费；输入 START 确认").Trim()
    return $answer -ceq 'START'
}

function Get-InstanceStatus {
    param($Instance)
    return [string](Get-ObjectProperty -Object $Instance -Names @('actual_status', 'status', 'cur_state') -Default 'unknown')
}

function Stop-ConnectionStartedInstance {
    param([int64]$Id)
    try {
        Write-Warning '连接验证失败，正在将本次启动的实例恢复为停止状态...'
        Invoke-VastText -Config $config -Arguments @('stop', 'instance', [string]$Id, '--raw') -TimeoutSeconds 45 | Out-Null
        Write-Host '实例已恢复为停止状态。' -ForegroundColor Yellow
    } catch {
        Write-Warning "无法自动恢复实例停止状态，请立即在 Vast 控制台检查计费：$($_.Exception.Message)"
    }
}

function Get-RemoteScriptDeploymentIdentity {
    param($Endpoint)

    $remoteCommand = @'
set -euo pipefail
manifest=/workspace/anima-project/records/vast-anima-deploy-manifest.json
if [[ -s "$manifest" ]] && jq -e '
  .schema_version == 1 and .created_by == "vast-anima-deploy" and
  (.application_type == "comfyui" or .application_type == "webui") and
  (.remote_port | type == "number") and (.local_port | type == "number")
' "$manifest" >/dev/null; then
  service_name=$(jq -r '.service_name' "$manifest")
  listen_host=$(jq -r '.listen_host' "$manifest")
  remote_port=$(jq -r '.remote_port' "$manifest")
  application_type=$(jq -r '.application_type' "$manifest")
  health_url="http://${listen_host}:${remote_port}"
  [[ "$application_type" != comfyui ]] || health_url+='/system_stats'
  supervisorctl status "$service_name" 2>/dev/null | grep -q RUNNING
  curl --silent --fail --max-time 5 "$health_url" >/dev/null
  jq -c . "$manifest"
  exit 0
fi

remote_root=/tmp/anima-vast-deploy
remote_config="$remote_root/remote-config.json"
verify_script="$remote_root/remote/verify-deployment.sh"
[[ -s "$remote_config" && -s "$verify_script" ]] || {
  echo 'This instance has no completed vast-anima-deploy marker.' >&2
  exit 42
}
project_root=$(jq -er '.codex.project_root' "$remote_config")
application_record="$project_root/records/deployment-application.json"
[[ -s "$application_record" ]] || { echo 'The deployment application record is missing.' >&2; exit 42; }
application_type=$(jq -er '.application.type' "$remote_config")
record_application=$(jq -er '.application' "$application_record")
[[ "$application_type" == "$record_application" ]] || { echo 'Deployment application records disagree.' >&2; exit 42; }
bash "$verify_script" "$remote_config" >&2
jq -cn \
  --arg created_by vast-anima-deploy \
  --arg application_type "$application_type" \
  --arg deployment_image "$(jq -r '.deployment_image // ""' "$remote_config")" \
  --arg service_name "$(jq -r --arg app "$application_type" '.[$app].service_name' "$remote_config")" \
  --arg listen_host "$(jq -r --arg app "$application_type" '.[$app].listen_host' "$remote_config")" \
  --argjson remote_port "$(jq -r --arg app "$application_type" '.[$app].port' "$remote_config")" \
  --argjson local_port "$(jq -r --arg app "$application_type" '.[$app].local_port // 0' "$remote_config")" \
  --arg application_root "$(jq -r --arg app "$application_type" '.[$app].root' "$remote_config")" \
  '{schema_version:1,created_by:$created_by,application_type:$application_type,
    deployment_image:$deployment_image,service_name:$service_name,listen_host:$listen_host,
    remote_port:$remote_port,local_port:$local_port,application_root:$application_root,
    verified_at:(now|todate),pre_manifest_verified:true}'
'@
    $arguments = @(Get-SshCommonArguments -Config $config) + @(
        '-o', 'LogLevel=QUIET', '-T', '-n', '-p', [string]$Endpoint.Port,
        "$($Endpoint.User)@$($Endpoint.Host)", $remoteCommand
    )
    $result = Invoke-NativeCommandCapture -Command 'ssh' -Arguments $arguments -TimeoutSeconds 180
    if ($result.ExitCode -ne 0) {
        throw "The remote instance is not a completed vast-anima-deploy deployment (exit $($result.ExitCode)).`n$($result.Text)"
    }
    $identity = ConvertFrom-LooseJson -Text $result.Text
    if ([int]$identity.schema_version -ne 1 -or [string]$identity.created_by -ne 'vast-anima-deploy' -or
        [string]$identity.application_type -notin @('comfyui', 'webui')) {
        throw 'The remote deployment marker is invalid.'
    }
    return $identity
}

$instances = @(Get-VastAccountInstances -Config $config -TimeoutSeconds 30)
$expectedLabel = [string]$config.Vast.Instance.Label
$eligible = @($instances | Where-Object {
    [string](Get-ObjectProperty -Object $_ -Names @('label') -Default '') -eq $expectedLabel
})
if ($eligible.Count -eq 0) {
    throw "当前 Vast 账户没有标签为 '$expectedLabel' 的实例。只有本脚本创建的实例可被连接。"
}

$selected = $null
if ($InstanceId -gt 0) {
    $selected = Find-VastInstanceInResponse -Response $eligible -InstanceId $InstanceId
    if ($null -eq $selected) { throw '指定实例不存在，或标签不属于 vast-anima-deploy。' }
} else {
    $attached = Get-AttachedInstanceState
    if ($null -ne $attached) {
        $remembered = Find-VastInstanceInResponse -Response $eligible -InstanceId ([int64]$attached.instance_id)
        if ($null -ne $remembered) {
            Write-Host ''
            Write-Host "已记住一个经过验证的 $($attached.application_type) 实例。" -ForegroundColor Cyan
            Write-Host '  1. 重新连接上次实例'
            Write-Host '  2. 重新查询并选择'
            Write-Host '  0. 取消'
            $savedChoice = Read-MenuNumber -Prompt '请选择操作' -Minimum 0 -Maximum 2
            if ($savedChoice -eq 0) { return }
            if ($savedChoice -eq 1) { $selected = $remembered }
        } else {
            Write-Warning '上次记住的附加实例已不在当前账户中，将重新查询。'
        }
    }

    if ($null -eq $selected) {
        Write-Host ''
        Write-Host "账户中由本脚本标签标识的实例：" -ForegroundColor Cyan
        ConvertTo-VastInstanceChoiceRows -Instances $eligible | Format-Table -AutoSize | Out-Host
        $choice = Read-MenuNumber -Prompt '请选择实例' -Minimum 1 -Maximum $eligible.Count
        $selected = $eligible[$choice - 1]
    }
}

$selectedId = [int64](Get-ObjectProperty -Object $selected -Names @('id', 'instance_id', 'contract_id'))
$status = Get-InstanceStatus -Instance $selected
$startedByThisRun = $false
try {
    if ($status -eq 'loading') {
        Wait-VastInstanceRunning -Config $config -InstanceId $selectedId | Out-Null
    } elseif ($status -ne 'running') {
        if ($status -notin @('exited', 'stopped', 'offline')) {
            throw "实例状态 '$status' 不支持安全启动连接。"
        }
        if (-not $StartIfStopped -and -not (Read-StartConfirmation -Status $status)) { throw '已取消连接，实例未启动。' }
        Write-Host '正在启动实例；GPU 计费将恢复。' -ForegroundColor Yellow
        $startedByThisRun = $true
        Invoke-VastText -Config $config -Arguments @('start', 'instance', [string]$selectedId, '--raw') -TimeoutSeconds 45 | Out-Null
        Wait-VastInstanceRunning -Config $config -InstanceId $selectedId | Out-Null
    }

    $endpoint = Wait-VastSshReady -Config $config -InstanceId $selectedId
    $identity = Get-RemoteScriptDeploymentIdentity -Endpoint $endpoint
} catch {
    if ($startedByThisRun) { Stop-ConnectionStartedInstance -Id $selectedId }
    if ($_.Exception.Message -match '(?i)permission denied|publickey|authentication failed|no supported authentication') {
        throw "$($_.Exception.Message)`n当前环境必须持有该实例接受的 SSH 私钥；请使用原环境私钥，或在 Vast 控制台为实例授权当前公钥。"
    }
    throw
}

$applicationType = [string]$identity.application_type
$localPort = [int](Get-ObjectProperty -Object $identity -Names @('local_port') -Default 0)
if ($localPort -le 0) {
    $localPort = if ($applicationType -eq 'comfyui') { [int]$config.ComfyUI.LocalPort } else { [int]$config.WebUI.LocalPort }
}
$deploymentImage = [string](Get-ObjectProperty -Object $identity -Names @('deployment_image') -Default '')
if (-not $deploymentImage) {
    $deploymentImage = [string](Get-ObjectProperty -Object $selected -Names @('image_uuid', 'image', 'image_name') -Default 'unknown')
}
$attachedState = [ordered]@{
    schema_version = 1
    source = 'external_script_instance'
    instance_id = $selectedId
    label = $expectedLabel
    application_type = $applicationType
    deployment_image = $deploymentImage
    service_name = [string]$identity.service_name
    listen_host = [string]$identity.listen_host
    remote_port = [int]$identity.remote_port
    local_port = $localPort
    application_root = [string]$identity.application_root
    ssh_host = [string]$endpoint.Host
    ssh_port = [int]$endpoint.Port
    verified_at = (Get-Date).ToUniversalTime().ToString('o')
}
Save-AttachedInstanceState -State $attachedState | Out-Null

Write-Host ''
Write-Host "已验证远端 vast-anima-deploy：$applicationType" -ForegroundColor Green
Write-Host "SSH：$($endpoint.User)@$($endpoint.Host):$($endpoint.Port)"
Write-Host "应用隧道：http://127.0.0.1:$localPort"
Write-Host '该实例仅被附加用于连接，不会进入本地部署、停止、销毁或卷管理流程。' -ForegroundColor Yellow

if ($Mode -eq 'Prompt') {
    Write-Host ''
    Write-Host '  1. 打开 SSH / tmux 终端'
    Write-Host '  2. 打开应用 SSH 隧道'
    Write-Host '  0. 返回'
    $operation = Read-MenuNumber -Prompt '请选择连接方式' -Minimum 0 -Maximum 2
    if ($operation -eq 0) { return }
    $Mode = if ($operation -eq 1) { 'Shell' } else { 'Tunnel' }
}

$common = @(Get-SshCommonArguments -Config $config)
$target = "$($endpoint.User)@$($endpoint.Host)"
if ($Mode -eq 'Tunnel') {
    Write-Host "保持此窗口打开，然后访问 http://127.0.0.1:$localPort" -ForegroundColor Green
    Invoke-NativeCommandChecked -Command 'ssh' -Arguments ($common + @(
        '-o', 'ExitOnForwardFailure=yes', '-p', [string]$endpoint.Port,
        '-N', '-L', "${localPort}:127.0.0.1:$([int]$identity.remote_port)", $target
    )) -FailureMessage '附加实例应用隧道失败。'
} else {
    Write-Host '正在打开远端 tmux 会话；输入 exit 返回 Windows。' -ForegroundColor Cyan
    $shellArguments = $common + @(
        '-tt', '-p', [string]$endpoint.Port, $target,
        'if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s anima; else exec /bin/bash -l; fi'
    )
    & ssh @shellArguments
    if ($LASTEXITCODE -ne 0) { throw "SSH exited with code $LASTEXITCODE." }
}
