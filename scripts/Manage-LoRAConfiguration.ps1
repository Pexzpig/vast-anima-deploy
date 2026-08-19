[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('Menu', 'List')][string]$Operation = 'Menu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'LoRA-Configuration.psm1') -Force

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'user-config\deployment.json' }
$resolvedConfigPath = Resolve-ProjectPath -Path $ConfigPath
$template = Get-DeployConfig -ConfigPath 'config.psd1'
$config = Add-CurrentFeatureConfigurationDefaults -Config (Get-DeployConfig -ConfigPath $resolvedConfigPath) -Template $template

function Read-ChoiceNumber {
    param([string]$Prompt, [int]$Minimum, [int]$Maximum)
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) { return $parsed }
        Write-Warning "请输入 $Minimum 到 $Maximum 之间的编号。"
    }
}

function Read-LoRAKind {
    Write-Host '  1. character（角色）'
    Write-Host '  2. style（画风）'
    if ((Read-ChoiceNumber -Prompt '选择 LoRA 类型' -Minimum 1 -Maximum 2) -eq 1) { return 'character' }
    return 'style'
}

function Read-LoRAStrength {
    while ($true) {
        $value = (Read-Host '推荐权重 [1.0]').Trim()
        if (-not $value) { return 1.0 }
        $parsed = 0.0
        if ([double]::TryParse($value, [ref]$parsed) -and $parsed -ge -2.0 -and $parsed -le 2.0) { return $parsed }
        Write-Warning '权重必须在 -2.0 到 2.0 之间。'
    }
}

function Get-LoRAInstallationStatus {
    param([hashtable]$CurrentConfig)

    $statuses = @{}
    foreach ($item in @($CurrentConfig.Anima.ManagedLoRAs)) {
        $status = '已禁用'
        if ([bool]$item.Enabled) { $status = '等待 Provision/未检查' }
        $itemName = [string]$item.Name
        $statuses[$itemName] = $status
    }
    if (@($CurrentConfig.Anima.ManagedLoRAs).Count -eq 0) { return $statuses }

    try {
        $summary = Get-LocalDeploymentSummary -Config $CurrentConfig
        if (-not $summary.Exists -or $summary.InstanceStatus -ne 'running') { return $statuses }
        $application = Get-DeploymentApplication -Config $CurrentConfig -State $summary.State
        $loraRoot = if ($application.Type -eq 'comfyui') {
            "$($CurrentConfig.ComfyUI.Root)/models/loras"
        } else {
            "$($CurrentConfig.WebUI.Root)/models/Lora"
        }
        if ($loraRoot -notmatch '^/[A-Za-z0-9._/-]+$') { return $statuses }
        $endpoint = Get-VastSshEndpoint -Config $CurrentConfig -InstanceId ([int64]$summary.State.instance_id)
        $remoteChecks = foreach ($item in @($CurrentConfig.Anima.ManagedLoRAs | Where-Object { $_.Enabled })) {
            $name = [string]$item.Name
            $sha = [string]$item.Sha256
            if ($name -notmatch '^[A-Za-z0-9._-]+\.safetensors$' -or $sha -notmatch '^[0-9a-fA-F]{64}$') {
                $statuses[$name] = '本地配置无效'
                continue
            }
            $path = "$loraRoot/$name"
            "if [ ! -s '$path' ]; then printf '$name\tmissing\n'; elif echo '$sha  $path' | sha256sum --check --status; then printf '$name\tinstalled\n'; else printf '$name\tmismatch\n'; fi"
        }
        if (@($remoteChecks).Count -eq 0) { return $statuses }
        $remoteCommand = $remoteChecks -join '; '
        $arguments = @(Get-SshCommonArguments -Config $CurrentConfig) + @(
            '-o', 'LogLevel=QUIET', '-T', '-n', '-p', [string]$endpoint.Port,
            "$($endpoint.User)@$($endpoint.Host)", $remoteCommand
        )
        $result = Invoke-NativeCommandCapture -Command 'ssh' -Arguments $arguments -TimeoutSeconds 45
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.Output) {
                $parts = @($line -split "`t", 2)
                if ($parts.Count -eq 2) {
                    $remoteStatus = '远端缺失'
                    if ($parts[1] -eq 'installed') { $remoteStatus = '已安装且哈希正确' }
                    elseif ($parts[1] -eq 'mismatch') { $remoteStatus = '远端同名文件哈希不符' }
                    $statuses[$parts[0]] = $remoteStatus
                }
            }
        }
    } catch {
        Write-Verbose "Could not query remote LoRA status: $($_.Exception.Message)"
    }
    return $statuses
}

function Show-LoRAList {
    param([hashtable]$CurrentConfig)

    $items = @($CurrentConfig.Anima.ManagedLoRAs)
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ' 用户 LoRA 清单' -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    if ($items.Count -eq 0) {
        Write-Host '清单为空。' -ForegroundColor DarkGray
        return
    }
    $statuses = Get-LoRAInstallationStatus -CurrentConfig $CurrentConfig
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $triggers = @($item.TriggerWords) -join ', '
        if (-not $triggers) { $triggers = '-' }
        $apply = '否（仅安装）'
        if ([bool]$item.AutoApplyInComfyUI) { $apply = '是' }
        $itemName = [string]$item.Name
        $itemStatus = $statuses[$itemName]
        Write-Host ("[{0}] {1}" -f ($index + 1), $item.Name) -ForegroundColor Green
        Write-Host ("    类型/来源：{0} / {1}    启用：{2}    ComfyUI 自动应用：{3}" -f $item.Kind, $item.Source, $item.Enabled, $apply)
        Write-Host ("    基础模型：{0}    推荐权重：{1}    状态：{2}" -f $item.BaseModel, $item.Strength, $itemStatus)
        Write-Host ("    触发词：{0}" -f $triggers)
        if ($item.OriginalFileName -and [string]$item.OriginalFileName -ne $itemName) {
            Write-Host ("    Civitai 原文件名：{0} -> {1}" -f $item.OriginalFileName, $itemName) -ForegroundColor DarkGray
        }
        if ($item.SourcePageUrl) { Write-Host ("    来源：{0}" -f $item.SourcePageUrl) -ForegroundColor DarkGray }
    }
}

function Get-LocalLoRAInstallationStatus {
    param([object[]]$Files)

    $statuses = @{}
    foreach ($file in @($Files)) { $statuses[[string]$file.RelativePath] = '等待 Provision/未检查' }
    if (@($Files).Count -eq 0) { return $statuses }
    try {
        $summary = Get-LocalDeploymentSummary -Config $config
        if (-not $summary.Exists -or $summary.InstanceStatus -ne 'running') { return $statuses }
        $application = Get-DeploymentApplication -Config $config -State $summary.State
        $loraRoot = if ($application.Type -eq 'comfyui') { "$($config.ComfyUI.Root)/models/loras" } else { "$($config.WebUI.Root)/models/Lora" }
        if ($loraRoot -notmatch '^/[A-Za-z0-9._/-]+$') { return $statuses }
        $payload = @($Files | ForEach-Object { [ordered]@{ RelativePath = $_.RelativePath; Sha256 = $_.Sha256 } }) | ConvertTo-Json -Depth 5 -Compress
        $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $statusScript = @'
import base64, hashlib, json, pathlib, sys
items = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
root = pathlib.Path(sys.argv[2]).resolve()
for item in items:
    destination = (root / pathlib.PurePosixPath(item["RelativePath"])).resolve()
    if root != destination and root not in destination.parents:
        state = "invalid"
    elif not destination.is_file():
        state = "missing"
    else:
        digest = hashlib.sha256()
        with destination.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        state = "installed" if digest.hexdigest() == item["Sha256"] else "mismatch"
    print(item["RelativePath"] + "\t" + state)
'@
        $script64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusScript))
        $endpoint = Get-VastSshEndpoint -Config $config -InstanceId ([int64]$summary.State.instance_id)
        $remoteCommand = "printf '%s' '$script64' | base64 -d | python3 - '$payload64' '$loraRoot'"
        $arguments = @(Get-SshCommonArguments -Config $config) + @(
            '-o', 'LogLevel=QUIET', '-T', '-n', '-p', [string]$endpoint.Port,
            "$($endpoint.User)@$($endpoint.Host)", $remoteCommand
        )
        $result = Invoke-NativeCommandCapture -Command 'ssh' -Arguments $arguments -TimeoutSeconds 120
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.Output) {
                $parts = @($line -split "`t", 2)
                if ($parts.Count -ne 2) { continue }
                $status = switch ($parts[1]) {
                    'installed' { '已安装且哈希正确' }
                    'mismatch' { '远端同名文件将被覆盖' }
                    'missing' { '远端缺失' }
                    default { '路径无效' }
                }
                $statuses[$parts[0]] = $status
            }
        }
    } catch {
        Write-Verbose "Could not query local LoRA status: $($_.Exception.Message)"
    }
    return $statuses
}

function Show-LocalLoRAList {
    $directory = Resolve-LocalLoRADirectory -ProjectRoot $script:ProjectRoot -RelativePath ([string]$config.Local.LoRADirectory) -Create
    $files = @(Get-LocalLoRAFiles -ProjectRoot $script:ProjectRoot -RelativeDirectory ([string]$config.Local.LoRADirectory))
    Write-Host ''
    Write-Host "本地 LoRA 目录：$directory" -ForegroundColor Cyan
    Write-Host '本地文件仅安装，不会自动加入 ComfyUI 工作流或 WebUI 提示词。' -ForegroundColor DarkGray
    if ($files.Count -eq 0) { Write-Host '  未发现 .safetensors 文件。' -ForegroundColor DarkGray; return }
    $statuses = Get-LocalLoRAInstallationStatus -Files $files
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        Write-Host ("  [{0}] {1}  {2:N1} MB  {3}" -f ($index + 1), $file.RelativePath, ($file.SizeBytes / 1MB), $statuses[[string]$file.RelativePath])
    }
}

function Show-CivitaiCredentialStatus {
    $tokenName = [string]$config.Secrets.CivitaiTokenEnvironmentVariable
    $storedPath = Get-CivitaiCredentialPath -ProjectRoot $script:ProjectRoot
    $storedState = '未保存'
    if (Test-Path -LiteralPath $storedPath -PathType Leaf) {
        try {
            Get-CivitaiStoredCredential -ProjectRoot $script:ProjectRoot | Out-Null
            $storedState = '已加密保存且可读取'
        } catch {
            $storedState = '文件存在但当前用户无法解密，请重新录入'
        }
    }
    $environmentState = if ([Environment]::GetEnvironmentVariable($tokenName, 'Process')) { '当前进程已设置' } else { '未设置' }
    Write-Host "Civitai API Key：本机=$storedState；$tokenName=$environmentState" -ForegroundColor DarkCyan
    Write-Host '保存的凭据优先用于 Civitai API 和远端下载，密钥内容不会显示。' -ForegroundColor DarkGray
}

function Save-LoRAConfig {
    Save-JsonFile -Path $resolvedConfigPath -Value $config | Out-Null
    Write-Host "LoRA 清单已保存：$resolvedConfigPath" -ForegroundColor Green
    Write-Host '运行中的实例不会自动修改；需要时执行菜单“重新执行配置部署”。' -ForegroundColor Yellow
}

function Add-LoRAEntry {
    param([hashtable]$Entry)
    $name = [string]$Entry.Name
    if ($name -eq [string]$config.Anima.Turbo.Name -or @($config.Anima.ManagedLoRAs | Where-Object { [string]$_.Name -ieq $name }).Count -gt 0) {
        throw "LoRA 文件名已存在：$name"
    }
    $config.Anima.ManagedLoRAs = @($config.Anima.ManagedLoRAs) + @($Entry)
    Save-LoRAConfig
}

function Add-CivitaiLoRA {
    $url = (Read-Host '粘贴 Civitai 模型页面或下载链接').Trim()
    $kind = Read-LoRAKind
    $strength = Read-LoRAStrength
    $tokenName = [string]$config.Secrets.CivitaiTokenEnvironmentVariable
    $credential = Get-CivitaiCredential -ProjectRoot $script:ProjectRoot -EnvironmentVariableName $tokenName
    $token = if ($credential) { [string]$credential.Value } else { $null }

    $versionSelector = {
        param($Versions)
        Write-Host '该模型有多个版本，请固定一个版本：'
        for ($index = 0; $index -lt @($Versions).Count; $index++) {
            $version = @($Versions)[$index]
            Write-Host ("  {0}. {1}  base={2}  id={3}" -f ($index + 1), $version.name, $version.baseModel, $version.id)
        }
        $choice = Read-ChoiceNumber -Prompt '选择版本' -Minimum 1 -Maximum @($Versions).Count
        return [int64]@($Versions)[$choice - 1].id
    }
    $fileSelector = {
        param($Files)
        Write-Host '该版本有多个 SafeTensor 文件，请固定一个文件：'
        for ($index = 0; $index -lt @($Files).Count; $index++) {
            $file = @($Files)[$index]
            Write-Host ("  {0}. {1}  {2:N1} MB  id={3}" -f ($index + 1), $file.name, ([double]$file.sizeKB / 1024), $file.id)
        }
        $choice = Read-ChoiceNumber -Prompt '选择文件' -Minimum 1 -Maximum @($Files).Count
        return @($Files)[$choice - 1]
    }
    $entry = Resolve-CivitaiLoRAEntry -Url $url -Kind $kind -Strength $strength -Token $token `
        -VersionSelector $versionSelector -FileSelector $fileSelector `
        -ExistingNames (@([string]$config.Anima.Turbo.Name) + @($config.Anima.ManagedLoRAs | ForEach-Object { [string]$_.Name }))
    Add-LoRAEntry -Entry $entry
}

function Set-CivitaiApiKey {
    Write-Host 'API Key 只会以当前 Windows 用户可解密的形式保存在本机，不会写入 deployment.json。' -ForegroundColor DarkCyan
    $secureToken = Read-Host '输入 Civitai API Key' -AsSecureString
    $civitaiEntries = @($config.Anima.ManagedLoRAs | Where-Object { [string]$_.Source -eq 'civitai' })
    if ($civitaiEntries.Count -gt 0) {
        $downloadUrl = [string]$civitaiEntries[0].Url
        Test-CivitaiDownloadCredential -SecureToken $secureToken -DownloadUrl $downloadUrl | Out-Null
        Write-Host 'Civitai 下载认证验证成功。' -ForegroundColor Green
    } else {
        Write-Warning '清单中还没有 Civitai LoRA，暂时只能检查 Key 格式；添加 LoRA 后可重新录入以验证下载权限。'
    }
    $path = Set-CivitaiStoredCredential -ProjectRoot $script:ProjectRoot -SecureToken $secureToken
    Write-Host "Civitai API Key 已加密保存：$path" -ForegroundColor Green
    Write-Host '重新执行 Provision 时会自动安全上传该凭据。' -ForegroundColor Yellow
}

function Clear-CivitaiApiKey {
    Write-Host '这会删除本机保存的 Civitai API Key，并清除当前 PowerShell 进程中的对应环境变量。' -ForegroundColor Yellow
    if ((Read-Host '输入 CLEAR 确认').Trim() -cne 'CLEAR') { Write-Host '已取消。'; return }
    Remove-CivitaiStoredCredential -ProjectRoot $script:ProjectRoot
    [Environment]::SetEnvironmentVariable([string]$config.Secrets.CivitaiTokenEnvironmentVariable, $null, 'Process')
    Write-Host 'Civitai API Key 已清除。' -ForegroundColor Green
}

function Set-LocalLoRADirectory {
    Write-Host "当前目录：$($config.Local.LoRADirectory)"
    $relativePath = (Read-Host '输入项目内相对目录').Trim()
    if (-not $relativePath) { Write-Host '已取消。'; return }
    $resolved = Resolve-LocalLoRADirectory -ProjectRoot $script:ProjectRoot -RelativePath $relativePath -Create
    $config.Local.LoRADirectory = $relativePath.Trim().TrimEnd([char[]]'\/').Replace('\', '/')
    Save-LoRAConfig
    Write-Host "本地 LoRA 目录：$resolved" -ForegroundColor Green
}

function Open-LocalLoRADirectory {
    $resolved = Resolve-LocalLoRADirectory -ProjectRoot $script:ProjectRoot -RelativePath ([string]$config.Local.LoRADirectory) -Create
    if ($env:OS -eq 'Windows_NT') {
        Invoke-Item -LiteralPath $resolved
        Write-Host "已打开：$resolved" -ForegroundColor Green
    } else {
        Write-Host "本地 LoRA 目录：$resolved"
    }
}

function Add-DirectLoRA {
    $url = (Read-Host '输入公开 HTTPS 文件直链').Trim()
    $name = (Read-Host '远端文件名（必须以 .safetensors 结尾）').Trim()
    $sha = (Read-Host 'SHA-256（64 位十六进制）').Trim()
    $kind = Read-LoRAKind
    $strength = Read-LoRAStrength
    $triggerText = (Read-Host '触发词（可选，逗号分隔）').Trim()
    $triggers = if ($triggerText) { @($triggerText -split '[,，]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    Write-Host '直链无法自动验证模型卡。只有确认该文件兼容 Anima 时才能继续。' -ForegroundColor Yellow
    if ((Read-Host '输入 ANIMA 确认').Trim() -cne 'ANIMA') { Write-Host '已取消。'; return }
    Add-LoRAEntry -Entry (New-DirectLoRAEntry -Url $url -Name $name -Kind $kind -Sha256 $sha -Strength $strength -TriggerWords $triggers)
}

function Select-LoRAIndex {
    $items = @($config.Anima.ManagedLoRAs)
    if ($items.Count -eq 0) { Write-Host '清单为空。' -ForegroundColor Yellow; return -1 }
    Show-LoRAList -CurrentConfig $config
    return (Read-ChoiceNumber -Prompt '选择 LoRA' -Minimum 1 -Maximum $items.Count) - 1
}

function Toggle-LoRA {
    $index = Select-LoRAIndex
    if ($index -lt 0) { return }
    $item = @($config.Anima.ManagedLoRAs)[$index]
    $item.Enabled = -not [bool]$item.Enabled
    Save-LoRAConfig
}

function Remove-LoRA {
    $index = Select-LoRAIndex
    if ($index -lt 0) { return }
    $items = @($config.Anima.ManagedLoRAs)
    $item = $items[$index]
    Write-Host "只会从本地清单移除 $($item.Name)，不会删除远端文件。" -ForegroundColor Yellow
    if ((Read-Host '输入 REMOVE 确认').Trim() -cne 'REMOVE') { Write-Host '已取消。'; return }
    $remaining = @()
    for ($itemIndex = 0; $itemIndex -lt $items.Count; $itemIndex++) {
        if ($itemIndex -ne $index) { $remaining += $items[$itemIndex] }
    }
    $config.Anima.ManagedLoRAs = $remaining
    Save-LoRAConfig
}

if ($Operation -eq 'List') {
    Show-CivitaiCredentialStatus
    Show-LoRAList -CurrentConfig $config
    Show-LocalLoRAList
    exit 0
}

while ($true) {
    Show-CivitaiCredentialStatus
    Show-LoRAList -CurrentConfig $config
    Show-LocalLoRAList
    Write-Host ''
    Write-Host '  1. 添加 Civitai LoRA'
    Write-Host '  2. 添加公开 HTTPS 直链'
    Write-Host '  3. 启用/停用条目'
    Write-Host '  4. 从清单移除（不删除远端文件）'
    Write-Host '  5. 设置本地 LoRA 目录'
    Write-Host '  6. 打开本地 LoRA 目录'
    Write-Host '  7. 录入 Civitai API Key（Anima LoRA 下载）'
    Write-Host '  8. 清除 Civitai API Key'
    Write-Host '  0. 返回主菜单'
    $choice = Read-ChoiceNumber -Prompt '请选择操作' -Minimum 0 -Maximum 8
    switch ($choice) {
        0 { exit 0 }
        1 { Add-CivitaiLoRA }
        2 { Add-DirectLoRA }
        3 { Toggle-LoRA }
        4 { Remove-LoRA }
        5 { Set-LocalLoRADirectory }
        6 { Open-LocalLoRADirectory }
        7 { Set-CivitaiApiKey }
        8 { Clear-CivitaiApiKey }
    }
}
