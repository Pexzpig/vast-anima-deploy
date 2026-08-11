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

function Resolve-SshIdentityPath {
    param([string]$Path)

    if (-not $Path) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') { return [Environment]::GetFolderPath('UserProfile') }
    if ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        return Join-Path ([Environment]::GetFolderPath('UserProfile')) $expanded.Substring(2)
    }
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return Resolve-ProjectPath -Path $expanded
}

function Get-OrCreateSshKeyPair {
    $sshDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
    $candidatePrivateKeys = @()
    $configuredIdentity = Resolve-SshIdentityPath -Path ([string]$config.Vast.Ssh.IdentityFile)
    if ($configuredIdentity) { $candidatePrivateKeys += $configuredIdentity }
    foreach ($name in @('id_ed25519', 'id_ed25519_vast_anima', 'id_ecdsa', 'id_rsa')) {
        $candidatePrivateKeys += (Join-Path $sshDirectory $name)
    }

    foreach ($privateKey in ($candidatePrivateKeys | Select-Object -Unique)) {
        $publicKey = "$privateKey.pub"
        if (Test-SshKeyPairUsable -PrivateKeyPath $privateKey -PublicKeyPath $publicKey) {
            $fingerprintResult = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @('-lf', $publicKey)
            if ($fingerprintResult.ExitCode -eq 0) {
                return [pscustomobject]@{
                    PrivateKeyPath = $privateKey
                    PublicKeyPath = $publicKey
                    Fingerprint = $fingerprintResult.Text
                    Created = $false
                }
            }
        }
    }

    Assert-CommandExists -Name 'ssh-keygen'
    if (-not (Test-Path -LiteralPath $sshDirectory)) {
        New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
    }

    $privateKeyPath = Join-Path $sshDirectory 'id_ed25519'
    if ((Test-Path -LiteralPath $privateKeyPath) -or (Test-Path -LiteralPath "$privateKeyPath.pub")) {
        $privateKeyPath = Join-Path $sshDirectory 'id_ed25519_vast_anima'
        $suffix = 2
        while ((Test-Path -LiteralPath $privateKeyPath) -or (Test-Path -LiteralPath "$privateKeyPath.pub")) {
            $privateKeyPath = Join-Path $sshDirectory "id_ed25519_vast_anima_$suffix"
            $suffix++
        }
    }

    Write-Host "未发现同时具备私钥和公钥的可用 SSH key；正在自动生成 $privateKeyPath" -ForegroundColor Yellow
    # Windows PowerShell 5.1 drops a native empty-string argument; literal
    # double quotes ensure ssh-keygen receives an empty passphrase for CLI use.
    $keygenResult = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @(
        '-t', 'ed25519', '-f', $privateKeyPath, '-N', '""', '-C', 'vast-anima-deploy'
    )
    $keygenResult.Output | Out-Host
    $publicKeyPath = "$privateKeyPath.pub"
    if ($keygenResult.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        throw 'SSH 密钥生成失败。'
    }

    $fingerprintResult = Invoke-NativeCommandCapture -Command 'ssh-keygen' -Arguments @('-lf', $publicKeyPath)
    if ($fingerprintResult.ExitCode -ne 0) { throw "SSH 公钥校验失败：$($fingerprintResult.Text)" }
    return [pscustomobject]@{
        PrivateKeyPath = $privateKeyPath
        PublicKeyPath = $publicKeyPath
        Fingerprint = $fingerprintResult.Text
        Created = $true
    }
}

function Ensure-VastSshKey {
    param(
        [string]$CliPath,
        $KeyPair,
        $AuthenticationStatus
    )

    $markerPath = Resolve-ProjectPath -Path 'user-config/environment.json'
    Write-Host '正在确认 Vast.ai 账户中的 SSH 公钥...' -ForegroundColor Cyan
    $listResult = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('show', 'ssh-keys', '--raw')
    if ($listResult.ExitCode -ne 0) {
        throw "[VAST_SSH_CHECK_FAILED] 无法读取 Vast.ai 账户 SSH keys。请确认 API key 具有账户读取权限。`n$($listResult.Text)"
    }

    $accountText = "$($AuthenticationStatus.RawText)`n$($listResult.Text)"
    $registered = Test-SshPublicKeyRegistered -PublicKeyPath $KeyPair.PublicKeyPath -AccountText $accountText

    if (-not $registered) {
        Write-Host "账户尚未注册当前本机公钥，正在自动注册：$($KeyPair.PublicKeyPath)" -ForegroundColor Yellow
        $createResult = Invoke-NativeCommandCapture -Command $CliPath -Arguments @(
            'create', 'ssh-key', $KeyPair.PublicKeyPath, '-y'
        )
        if ($createResult.ExitCode -ne 0) {
            $message = $createResult.Text
            if ($message -notmatch '(?i)already|exist|duplicate') {
                throw "自动注册 SSH 公钥失败：$message"
            }
        }

        for ($attempt = 1; $attempt -le 3 -and -not $registered; $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Seconds 1 }
            $verification = Invoke-NativeCommandCapture -Command $CliPath -Arguments @('show', 'ssh-keys', '--raw')
            if ($verification.ExitCode -eq 0) {
                $refreshedAuth = Get-VastAuthenticationStatus -CliPath $CliPath
                $accountText = "$($refreshedAuth.RawText)`n$($verification.Text)"
                $registered = Test-SshPublicKeyRegistered -PublicKeyPath $KeyPair.PublicKeyPath -AccountText $accountText
            }
        }
        if (-not $registered) {
            throw '[VAST_SSH_VERIFY_FAILED] SSH 公钥提交后仍未在 Vast.ai 账户中查到，请检查 API key 权限。'
        }
    }

    Save-JsonFile -Path 'user-config/environment.json' -Value ([ordered]@{
        private_key_path = $KeyPair.PrivateKeyPath
        public_key_path = $KeyPair.PublicKeyPath
        fingerprint = $KeyPair.Fingerprint
        vast_user_id = $AuthenticationStatus.UserId
        verified = $true
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
    }) | Out-Null

    return [pscustomobject]@{
        Registered = $true
        PublicKeyPath = $KeyPair.PublicKeyPath
        PrivateKeyPath = $KeyPair.PrivateKeyPath
        Fingerprint = $KeyPair.Fingerprint
    }
}

Write-Host ''
Write-Host '检测本地部署环境...' -ForegroundColor Cyan
if ($PSVersionTable.PSVersion.Major -lt 5) { throw '需要 PowerShell 5.1 或更高版本。' }
foreach ($command in @('ssh', 'scp', 'ssh-keygen')) { Assert-CommandExists -Name $command }
$cliPath = Ensure-VastCli
$authStatus = $null
$keyPair = $null
$sshStatus = $null

if (-not $SkipAuthentication) {
    $authStatus = Get-VastAuthenticationStatus -CliPath $cliPath
    if (-not $authStatus.Authenticated) {
        if ($NonInteractive) { throw '[VAST_AUTH_REQUIRED] Vast CLI 尚未认证，非交互模式无法读取 API key。' }
        $envName = [string]$config.Secrets.VastApiKeyEnvironmentVariable
        $invalidEnvironmentKey = [Environment]::GetEnvironmentVariable($envName, 'Process')
        if ($invalidEnvironmentKey) {
            Write-Warning "$envName 当前值未通过 Vast 登录验证；它会覆盖 CLI 本地凭据，本次运行将忽略该值。"
            [Environment]::SetEnvironmentVariable($envName, $null, 'Process')
        }
        Write-Host ''
        Write-Host 'Vast CLI 尚未登录。请从 Vast.ai 控制台 Keys 页面复制 API key。' -ForegroundColor Yellow
        Write-Host '接下来由 CLI 的 set api-key 流程安全写入本机 Vast 配置，不会写入本项目。' -ForegroundColor Yellow
        while (-not $authStatus.Authenticated) {
            try {
                & (Join-Path $PSScriptRoot 'Initialize-Vast.ps1') -ConfigPath $ConfigPath -IgnoreEnvironment
                $authStatus = Get-VastAuthenticationStatus -CliPath $cliPath
            }
            catch {
                Write-Warning "Vast CLI 登录未通过：$($_.Exception.Message)"
            }
            if (-not $authStatus.Authenticated -and
                -not (Read-EnvironmentApproval -Prompt '是否重新输入 Vast API key？')) {
                throw '[VAST_AUTH_VERIFY_FAILED] Vast CLI 登录未完成。'
            }
        }
    }
    Write-Host "Vast 登录有效：$(if ($authStatus.Email) { $authStatus.Email } else { "user $($authStatus.UserId)" })" -ForegroundColor Green
    $keyPair = Get-OrCreateSshKeyPair
    $sshStatus = Ensure-VastSshKey -CliPath $cliPath -KeyPair $keyPair -AuthenticationStatus $authStatus
    Write-Host "SSH 配置有效：$($sshStatus.Fingerprint)" -ForegroundColor Green
}

Write-Host '环境检测通过。' -ForegroundColor Green
if ($PassThru) {
    [pscustomobject]@{
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        VastCli = $cliPath
        Authenticated = if ($SkipAuthentication) { $false } else { [bool]$authStatus.Authenticated }
        VastUserId = if ($SkipAuthentication) { $null } else { $authStatus.UserId }
        VastEmail = if ($SkipAuthentication) { $null } else { $authStatus.Email }
        SshRegistered = if ($SkipAuthentication) { $false } else { [bool]$sshStatus.Registered }
        SshPrivateKey = if ($SkipAuthentication) { $null } else { $sshStatus.PrivateKeyPath }
        SshPublicKey = if ($SkipAuthentication) { $null } else { $sshStatus.PublicKeyPath }
    }
}
