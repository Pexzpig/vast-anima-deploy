# Vast.ai + ComfyUI + Anima + Codex CLI 示例部署

这是一套面向 Windows 本地控制端和 Vast.ai Linux GPU 实例的示例脚本。

它完成以下流程：

1. 从 `config.psd1` 读取固定的 GPU 搜索范围；
2. 每次部署都重新执行该范围，不静默扩大搜索条件；
3. 为候选 GPU 查找同一 `machine_id` 上的本地卷；
4. 创建卷和 SSH 实例，并把 ID 写入 `state/deployment.json`；
5. 通过 SSH 安装 ComfyUI、Anima Base v1 官方模型和官方 workflow；
6. 让 ComfyUI 只监听远端 `127.0.0.1:18188`，通过 SSH 隧道访问；
7. 安装 Codex CLI，但不自动上传或持久化 OpenAI 凭据；
8. 提供启动、暂停、销毁实例和删除卷脚本。

Vast 会对实例和存储计费。`New-VastDeployment.ps1` 默认要求输入 `RENT`，销毁和删除操作也有独立确认；自动化时才使用 `-Force`。

## 目录

```text
vast-anima-deploy/
├── config.psd1               # 完整配置，不包含密钥
├── remote/
│   ├── provision.sh          # 远端 ComfyUI/Anima 配置
│   └── configure-codex.sh    # 远端 Codex 配置
├── scripts/
│   ├── Initialize-Vast.ps1
│   ├── Test-Configuration.ps1
│   ├── Search-VastOffers.ps1
│   ├── New-VastDeployment.ps1
│   ├── Provision-Instance.ps1
│   ├── Deploy-Example.ps1
│   ├── Open-ComfyUITunnel.ps1
│   ├── Get-DeploymentStatus.ps1
│   ├── Start-VastInstance.ps1
│   ├── Stop-VastInstance.ps1
│   ├── Destroy-VastInstance.ps1
│   └── Remove-VastVolume.ps1
└── state/                    # 搜索结果和当前部署 ID；被 Git 忽略
```

## 1. 本地前置条件

- Windows PowerShell 5.1 或 PowerShell 7；
- Python 3；
- OpenSSH 的 `ssh` 和 `scp`；
- Vast.ai 账户、余额、API key 和已注册的 SSH 公钥。

如果系统阻止本地 `.ps1`，只对当前 PowerShell 进程临时放行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

安装 Vast CLI：

```powershell
py -m pip install --upgrade vastai
vastai --help
```

如果 SSH 公钥尚未注册：

```powershell
vastai create ssh-key "$HOME\.ssh\id_ed25519.pub"
```

Vast 官方 CLI 指南：<https://docs.vast.ai/cli/hello-world>

## 2. 创建并检查配置

```powershell
Set-Location E:\Documents\img1\vast-anima-deploy
notepad .\config.psd1
.\scripts\Test-Configuration.ps1
```

重点确认：

- `Vast.Search.Query`：允许的 GPU、显存、可靠性、网络、CUDA 和最高时价；
- `Vast.Search.MaxHourlyUsd`：脚本侧的第二道价格上限；
- `Vast.Instance.Image`：示例使用 Vast 官方 base-image；
- `Vast.Volume.SizeGb`：模型、环境、workflow 和输出的持久卷容量；
- `Vast.Ssh.IdentityFile`：留空使用系统默认 SSH key；
- `ComfyUI.Port` 与 `Vast.Ssh.LocalComfyPort`；
- `Anima.Models`：官方 Base、Qwen 文本编码器和 Qwen Image VAE；
- `Codex.ApprovalPolicy` 与 `Codex.SandboxMode`。

默认搜索范围只接受单卡、16GB 以上显存、Vast 已验证、可靠性高于 0.98、下载带宽大于 200Mbps、CUDA 12.8+、价格不高于 0.80 美元/小时的指定 GPU。它只是保守示例，应按账户所在地和市场供给主动修改。

配置中的密钥字段保存的是“环境变量名称”，不是密钥本身：

| 配置键 | 默认环境变量 | 是否必需 |
|---|---|---|
| `Secrets.VastApiKeyEnvironmentVariable` | `VAST_API_KEY` | 本地初始化 Vast CLI 时必需 |
| `Secrets.OpenAIApiKeyEnvironmentVariable` | `OPENAI_API_KEY` | 可选；Codex 默认用设备码登录 |
| `Secrets.HuggingFaceTokenEnvironmentVariable` | `HF_TOKEN` | 当前公开 Anima 文件不需要 |

## 3. 初始化 Vast CLI 身份

不要把 API key 写入 `config.psd1`。直接运行脚本，它会使用安全输入框询问：

```powershell
.\scripts\Initialize-Vast.ps1
```

`Initialize-Vast.ps1` 调用 Vast CLI 的 `set api-key`，将凭据保存到 Vast CLI 的用户配置位置。CI 场景也可以事先设置 `VAST_API_KEY` 环境变量，但不要在终端历史、日志或仓库中记录值。

## 4. 只搜索，不租用

```powershell
.\scripts\Search-VastOffers.ps1
```

结果保存到 `state/last-search.json`。部署脚本不会直接复用旧报价；它会再次调用该搜索脚本。

Vast 搜索语法和字段：<https://docs.vast.ai/cli/reference/search-instances>

## 5. 完整示例部署

```powershell
.\scripts\Deploy-Example.ps1
```

流程中会显示候选 GPU、时价和卷信息，并要求输入 `RENT`。它依次执行：

- `New-VastDeployment.ps1`：重新搜索、创建同机卷、创建实例、等待 SSH；
- `Provision-Instance.ps1`：上传非敏感配置和远端脚本，安装并验证服务。

无人值守场景可使用：

```powershell
.\scripts\Deploy-Example.ps1 -Force
```

远端安装内容：

- `/workspace/ComfyUI`；
- `/workspace/ComfyUI/models/diffusion_models/anima-base-v1.0.safetensors`；
- `/workspace/ComfyUI/models/text_encoders/qwen_3_06b_base.safetensors`；
- `/workspace/ComfyUI/models/vae/qwen_image_vae.safetensors`；
- `/workspace/anima-project/workflows/original/image_anima_base_v1.json`；
- `/workspace/anima-project/records/anima-baseline.json`；
- Supervisor 服务 `comfyui`；
- Codex CLI 和项目级 `.codex/config.toml`。

- Anima 官方模型卡：<https://huggingface.co/circlestone-labs/Anima>
- ComfyUI 官方 Anima workflow：<https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_anima_base_v1.json>

## 6. 打开 ComfyUI

```powershell
.\scripts\Open-ComfyUITunnel.ps1
```

保持终端打开，然后访问：

```text
http://127.0.0.1:18188
```

远端 ComfyUI 不监听公网地址。关闭 SSH 隧道不会停止 ComfyUI 或实例。

## 7. Codex 登录和运行

先使用状态脚本查看 SSH 地址：

```powershell
.\scripts\Get-DeploymentStatus.ps1
```

SSH 登录实例后：

```bash
/workspace/bin/codex-login.sh
/workspace/bin/run-codex.sh
```

登录脚本使用 `codex login --device-auth`。在本地浏览器打开终端给出的地址并输入一次性代码。Codex 的认证文件保留在实例容器的 root home，而不是 `/workspace` 持久卷。

如必须使用 API key，应在远端交互式终端通过 stdin 登录，不要把 key 放到 Vast 模板、workflow、Git 或本项目配置中：

```bash
read -rsp 'OpenAI API key: ' OPENAI_API_KEY
printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key
unset OPENAI_API_KEY
```

Codex 官方安装和 headless 认证：

- <https://developers.openai.com/codex/cli/>
- <https://developers.openai.com/codex/auth/>

## 8. 实例生命周期

查看状态：

```powershell
.\scripts\Get-DeploymentStatus.ps1
```

暂停计算：

```powershell
.\scripts\Stop-VastInstance.ps1
```

暂停会停止计算计费，但实例磁盘和卷的存储费用继续产生。

重新启动：

```powershell
.\scripts\Start-VastInstance.ps1
```

Vast 不保证原机器 GPU 在恢复时仍有空闲资源；脚本会等待并报告终止状态或超时。

永久销毁实例：

```powershell
.\scripts\Destroy-VastInstance.ps1
# 自动化：.\scripts\Destroy-VastInstance.ps1 -Force
```

单独创建的卷不会随实例销毁而删除。

永久删除卷：

```powershell
.\scripts\Remove-VastVolume.ps1
# 自动化：.\scripts\Remove-VastVolume.ps1 -Force
```

Vast 要求先销毁所有挂载该卷的实例。卷删除不可恢复。

生命周期命令参考：

- <https://docs.vast.ai/cli/reference/start-instance>
- <https://docs.vast.ai/cli/reference/stop-instance>
- <https://docs.vast.ai/cli/reference/destroy-instance>
- <https://docs.vast.ai/cli/reference/delete-volume>

## 9. 幂等性和恢复边界

- 已存在且校验通过的模型不会重新下载；
- 原始 workflow 存在时不会覆盖；
- 已有 ComfyUI Git checkout 只允许 fast-forward 更新，不丢弃本地改动；
- 写 Codex 项目配置前会创建带 UTC 时间戳的备份；
- 远端配置失败时，付费资源不会被脚本自动销毁，避免误删数据；应检查状态后主动决定暂停、销毁或重试配置；
- 若实例创建失败但卷已创建，卷 ID 会保留在 `state/deployment.json`，可以单独删除；
- 新部署不会覆盖仍指向活动实例或保留卷的 state，防止付费资源被遗忘；
- Vast 本地卷绑定物理机器，不是跨机器高可用存储。重要 workflow 和输出仍需复制到本地或对象存储。

## 10. 常见问题

### 搜索不到同时支持卷的 GPU

脚本会依次尝试当前搜索结果，寻找同一 `machine_id` 的卷报价。可以在 `config.psd1` 中明确调整 GPU 范围、价格、可靠性或关闭 `Vast.Volume.Enabled`；不要在脚本里绕过配置范围。

### ComfyUI 配置失败

SSH 登录后查看：

```bash
supervisorctl status comfyui
tail -n 100 /workspace/logs/comfyui.log
nvidia-smi
curl http://127.0.0.1:18188/system_stats
```

### 模型下载中断

重新执行 `Provision-Instance.ps1`。远端下载使用可续传的 `.part` 文件。VAE 配置了官方 SHA-256；其余大文件在配置未提供校验值时至少要求下载成功且文件非空。

### Anima 商业使用

当前 Hugging Face 模型页标注 CircleStone Labs 非商业许可证。部署脚本不会改变或替代模型许可证，商业使用前应单独核对完整条款。
