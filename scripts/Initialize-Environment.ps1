[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NonInteractive,
    [switch]$SkipAuthentication,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ProjectRoot 'config.psd1' }
$config = Get-DeployConfig -ConfigPath $ConfigPath

function Read-EnvironmentApproval {
    param([string]$Prompt)

    if ($NonInteractive) { throw "$Prompt 需要交互确认，但当前使用了 -NonInteractive。" }
    while ($true) {
        $answer = (Read-Host "$Prompt [Y/n]").Trim().ToLowerInvariant()
        if (-not $answer -or $answer -in @('y', 'yes', '是', '好')) { return $true }
        if ($answer -in @('n', 'no', '否', '不')) { return $false }
        Write-Warning '请输入 y 或 n。'
    }
}

function Find-PythonCommand {
    foreach ($name in @('py', 'python')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $name }
    }
    return $null
}

function Refresh-PythonScriptsPath {
    param([string]$PythonCommand)

    $candidates = @()
    try {
        $userBase = (& $PythonCommand -c 'import site; print(site.USER_BASE)' 2>$null | Select-Object -Last 1).Trim()
        if ($userBase) { $candidates += (Join-Path $userBase 'Scripts') }
    } catch {}
    try {
        $executable = (& $PythonCommand -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1).Trim()
        if ($executable) {
            $pythonRoot = Split-Path -Parent $executable
            $candidates += $pythonRoot
            $candidates += (Join-Path $pythonRoot 'Scripts')
        }
    } catch {}

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath $candidate) -and (($env:Path -split ';') -notcontains $candidate)) {
            $env:Path = "$candidate;$env:Path"
        }
    }
}

function Ensure-VastCli {
    $cli = [string]$config.Vast.Cli
    $existing = Get-Command $cli -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    $python = Find-PythonCommand
    if (-not $python) {
        throw '未找到 Python。请先安装 Python 3 并重新运行本入口脚本。'
    }
    if (-not (Read-EnvironmentApproval -Prompt '未检测到 Vast CLI，是否现在自动安装/升级 vastai？')) {
        throw 'Vast CLI 是部署必需组件；安装被取消。'
    }

    Write-Host '正在安装 Vast CLI...' -ForegroundColor Cyan
    $installResult = Invoke-NativeCommandCapture -Command $python -Arguments @('-m', 'pip', 'install', '--upgrade', 'vastai')
    $installResult.Output | Out-Host
    if ($installResult.ExitCode -ne 0) { throw 'Vast CLI 安装失败，请检查网络和 Python/pip 配置。' }
    Refresh-PythonScriptsPath -PythonCommand $python

    $installed = Get-Command $cli -ErrorAction SilentlyContinue
    if (-not $installed) {
        throw 'vastai 已由 pip 安装，但当前进程仍未找到命令。请重新打开 PowerShell 后再次运行入口脚本。'
    }
    return $installed.Source
}

function Get-OrCreateSshPublicKey {
    $sshDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
    $preferred = Join-Path $sshDirectory 'id_ed25519.pub'
    $fallback = Join-Path $sshDirectory 'id_rsa.pub'
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    if (-not (Read-EnvironmentApproval -Prompt "未检测到 SSH 公钥，是否自动生成 $preferred？")) {
        throw 'SSH 公钥是连接 Vast 实例的必需组件；生成被取消。'
    }
    Assert-CommandExists -Name 'ssh-keygen'
    if (-not (Test-Path -LiteralPath $sshDirectory)) {
        New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
    }
    # Windows PowerShell 5.1 drops a native empty-string argument; literal
    # double quotes ensure ssh-keygen receives an empty passphrase for CLI use.
    $keygenResult = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @(
        '-t', 'ed25519', '-f', ($preferred -replace '\.pub$', ''), '-N', '""', '-C', 'vast-anima-deploy'
    )
    $keygenResult.Output | Out-Host
    if ($keygenResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $preferred)) {
        throw 'SSH 密钥生成失败。'
    }
    return $preferred
}

function Ensure-VastSshKey {
    param([string]$CliPath, [string]$PublicKeyPath)

    $markerPath = Resolve-ProjectPath -Path 'user-config/environment.json'
    $fingerprint = (& ssh-keygen -lf $PublicKeyPath 2>$null | Select-Object -First 1)
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.public_key_path -eq $PublicKeyPath -and $marker.fingerprint -eq $fingerprint) { return }
        } catch {}
    }

    Write-Host '正在确认 Vast.ai 账户中的 SSH 公钥...' -ForegroundColor Cyan
    $registered = $false
    $listResult = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('show', 'ssh-keys', '--raw')
    if ($listResult.ExitCode -eq 0) {
        $publicKeyParts = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim() -split '\s+'
        if ($publicKeyParts.Count -ge 2 -and ($listResult.Text -match [regex]::Escape($publicKeyParts[1]))) {
            $registered = $true
        }
    }

    if (-not $registered) {
        $createResult = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('create', 'ssh-key', $PublicKeyPath, '-y')
        if ($createResult.ExitCode -ne 0) {
            $message = $createResult.Text
            if ($message -notmatch '(?i)already|exist|duplicate') {
                throw "自动注册 SSH 公钥失败：$message"
            }
        }
    }

    Save-JsonFile -Path 'user-config/environment.json' -Value ([ordered]@{
        public_key_path = $PublicKeyPath
        fingerprint = [string]$fingerprint
        registered_at = (Get-Date).ToUniversalTime().ToString('o')
    }) | Out-Null
}

Write-Host ''
Write-Host '检测本地部署环境...' -ForegroundColor Cyan
if ($PSVersionTable.PSVersion.Major -lt 5) { throw '需要 PowerShell 5.1 或更高版本。' }
foreach ($command in @('ssh', 'scp', 'ssh-keygen')) { Assert-CommandExists -Name $command }
$cliPath = Ensure-VastCli

if (-not $SkipAuthentication) {
    if (-not (Test-VastAuthentication -CliPath $cliPath)) {
        if ($NonInteractive) { throw '[VAST_AUTH_REQUIRED] Vast CLI 尚未认证，非交互模式无法读取 API key。' }
        Write-Host 'Vast CLI 尚未认证，需要输入一次 API key（不会写入项目配置）。' -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot 'Initialize-Vast.ps1') -ConfigPath $ConfigPath
    }
    $publicKeyPath = Get-OrCreateSshPublicKey
    Ensure-VastSshKey -CliPath $cliPath -PublicKeyPath $publicKeyPath
}

Write-Host '环境检测通过。' -ForegroundColor Green
if ($PassThru) {
    [pscustomobject]@{
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        VastCli = $cliPath
        Authenticated = -not [bool]$SkipAuthentication
        SshPublicKey = if ($SkipAuthentication) { $null } else { $publicKeyPath }
    }
}
