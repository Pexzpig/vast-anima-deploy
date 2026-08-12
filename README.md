# Vast.ai + ComfyUI + Anima 自动部署

这套脚本从 Windows 终端自动完成 Vast.ai 环境检测、首次参数初始化、GPU 报价搜索、实例及可选持久卷创建、Anima 配置和 ComfyUI SSH 隧道管理。日常使用只有一个入口，不需要自己输入 `vastai` 命令，也不用在两套 profile 脚本之间手工切换。

```powershell
Set-Location E:\Documents\img1\vast-anima-deploy
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-VastAnima.ps1
```

Vast.ai 会对实例和存储计费。脚本只会在创建付费资源、销毁实例、永久删除持久卷、安装缺失组件或收集缺失凭据时要求用户确认/输入；检测、搜索、选择首个合格报价、部署和状态路由均自动完成。

## 首次运行

第一次运行 `Start-VastAnima.ps1` 会依次完成：

1. 检查 PowerShell、OpenSSH、Python 和 Vast CLI；
2. Vast CLI 缺失时询问一次，然后通过 Python/pip 自动安装；
3. 使用 `vastai show user --raw` 验证当前 API key；只有明确的 401/403 才进入登录引导，网络错误会单独报告；
4. 未登录时引导用户从 Vast Keys 页面取得 API key，并通过 CLI `set api-key` 保存，然后再次验证账户；
5. 检查本机 SSH 私钥与公钥是否真实匹配且适合非交互连接；没有可用 key pair 时自动生成专用 Ed25519 key；
6. 每次实时读取 Vast.ai 账户 SSH keys，必要时读取 `.pub` 文件内容、自动注册公钥并再次验证（兼容不会自行读取文件路径的 Vast CLI 版本）；
7. 在四页 CLI 向导中初始化部署和搜索参数；
8. 生成本地用户配置，最后询问是否立即搜索并部署。

API key 不写入仓库或生成的 JSON。环境中已设置 `VAST_API_KEY` 时会优先验证；如果该值无效，脚本会指出它覆盖了 CLI 本地凭据，在当前进程忽略它并引导重新登录。

### CLI 参数向导

向导不要求用户了解 Vast 查询语法，只需选择或输入：

- 部署配置：`vastai/comfy` 预装镜像或基础镜像；
- 允许的 GPU 型号或分类：GeForce RTX 30/40/50、RTX Ada/RTX PRO、RTX A 工作站，以及 A10/A40/L4/L40、A100/A800、H100/H200/B200 等现代数据中心系列；
- 最低显存和最高每小时 GPU 价格；
- 最低可靠度、下载速度和 CUDA 版本；
- 搜索结果上限；
- 是否启用持久卷及卷大小。

脚本会把选择转换为受限的 `Vast.Search.Query`。每次部署仍会重新搜索，不会复用过时报价，也不会静默放宽预算、GPU、可靠度或网络条件。

向导生成的本地文件为：

```text
user-config/
├── launcher.json          # 当前 profile 和配置路径
├── vast-comfy.json        # 预装镜像的用户参数（选择该 profile 时）
├── base-image.json        # 基础镜像的用户参数（选择该 profile 时）
└── environment.json       # 最近一次实时验证通过的 SSH key pair 和 Vast 用户标记
```

这些 JSON 已被 Git 忽略。它们不含 API key，但会包含本机 SSH 私钥/公钥路径。`environment.json` 只作为诊断记录；后续启动仍会实时检查 Vast 账户，不会仅凭该文件判断 SSH 已配置。

## 日常使用

直接运行入口脚本，按菜单编号操作：

```powershell
.\Start-VastAnima.ps1
```

菜单统一提供：

- 自动搜索并部署；
- 查看报价和部署状态；
- 打开 ComfyUI SSH 隧道；
- 重新执行远端配置；
- 启动、停止、销毁实例；
- 修改搜索参数或切换部署配置；
- 永久删除持久卷。

也可以指定单个动作，仍不需要调用 `vastai`：

```powershell
.\Start-VastAnima.ps1 -Action Search
.\Start-VastAnima.ps1 -Action Deploy
.\Start-VastAnima.ps1 -Action Status
.\Start-VastAnima.ps1 -Action Tunnel
.\Start-VastAnima.ps1 -Action Stop
.\Start-VastAnima.ps1 -Action Start
.\Start-VastAnima.ps1 -Action Configure
.\Start-VastAnima.ps1 -Action SwitchProfile
```

连接当前配置对应的远端命令行，并在连接前显示实例、GPU、价格、持久卷、
ComfyUI 端口和 Codex 参数：

```powershell
# 实例已经运行：显示参数并进入远端 shell
.\Open-VastRemoteCli.ps1

# 实例已经停止：恢复 GPU 计费、等待启动，然后进入远端 shell
.\Open-VastRemoteCli.ps1 -StartIfStopped

# 只显示参数和可复制的 SSH 命令，不实际连接
.\Open-VastRemoteCli.ps1 -ShowOnly
```

该入口只操作当前 `launcher.json` 选中的配置，不会创建实例或持久卷。
实例重启后会重新查询 SSH 主机和端口；不要继续使用旧日志中的端口。

`Search` 会在报价表中以 `price_USD_hour` 明确显示实例每小时美元价格。新建部署时，`Deploy` 会先让用户选择存储方式：创建独立持久卷，或只使用 `Vast.Instance.ContainerDiskGb` 指定的实例磁盘。然后脚本实时搜索并显示带序号、型号、显存、价格、可靠度、网速和机器 ID 的候选卡，由用户选择具体报价。只有持久卷模式会检查所选机器的卷报价。最终确认页会显示实例单价、选定存储方式、卷月价（如有）和估算合计时价；只有输入 `RENT` 才会创建和计费。没有任何远端资源 ID 的中断记录会标记为“未创建（可重试）”，不会阻塞下一次部署。

实例磁盘模式不会调用 `create volume`，也不会向 `create instance` 添加 `--link-volume`。当前默认实例磁盘为 30 GB；是否充足取决于镜像实际占用、输出数量和后续自定义模型，空间不足时应在新建实例前增大 `Vast.Instance.ContainerDiskGb`。停止实例会保留实例磁盘，销毁实例则会永久删除其中的 ComfyUI、模型、workflow、Codex 配置和所有输出。已经绑定持久卷的现有实例不能在线切换为实例磁盘；存储方式只在新建部署时选择。

`Destroy` 和 `RemoveVolume` 分开确认。销毁实例不会自动删除单独创建的持久卷；停止实例后，实例磁盘和卷仍会产生存储费用。

如果持久卷创建成功、实例创建失败，状态会保留卷 ID。再次选择 `Deploy` 时，脚本只列出该卷所在物理机器的当前 GPU 报价，并复用原卷重试实例创建，不会重复创建和计费第二个卷。若该机器暂时没有可用 GPU，可稍后重试，或先用 `RemoveVolume` 删除卷后改选其他机器。

如果实例已经创建、但等待运行或 provision 阶段中断，再次选择 `Deploy` 会从已有实例继续，不会重新租用实例或创建持久卷。

## 两套独立部署配置

| 项目 | `vast-comfy`（默认推荐） | `base-image` |
|---|---|---|
| 镜像 | `vastai/comfy:v0.28.0-cuda-12.9-py312` | `vastai/base-image:cuda-12.8.1-cudnn-devel-ubuntu22.04-py310` |
| ComfyUI | 镜像预装运行环境；持久卷为空时检出并校验 `v0.28.0` 源码 | provision 时克隆和安装 |
| 状态目录 | `profiles/vast-comfy/state/` | `state/` |
| 实例标签 | `anima-comfyui-preinstalled` | `anima-comfyui-example` |
| 卷前缀 | `anima_comfy_preinstalled` | `anima_comfyui` |
| 本地隧道 | `127.0.0.1:28188` | `127.0.0.1:18188` |
| 适合 | 更快启动、固定版本、较少安装步骤 | 修改源码、跟踪分支、深度定制 |

两套配置的 state、实例标签、卷标签、远端 provision 路径和本地端口互相独立，可以各自部署和管理。菜单中的“切换部署配置”只切换当前操作对象，不会停止、销毁或迁移另一套配置的资源；目标配置已有用户 JSON 时直接切换并保留原参数，尚未初始化时才打开一次参数向导。

预装版本复用镜像中的 Python、CUDA、PyTorch 和 Supervisor 配置。当持久卷挂载到 `/workspace` 并遮住镜像原有源码时，脚本会把固定版本的 ComfyUI checkout 检出到持久卷，再配置 Anima 模型、官方 workflow、基线记录和 Codex。已有非空且不是 Git checkout 的目录不会被覆盖。

升级预装镜像时必须同步修改：

```text
Vast.Instance.Image = vastai/comfy:<version>-<cuda>-<python>
ComfyUI.Ref         = <version>
```

`/workspace` 使用持久卷时，旧卷可能保留旧版 ComfyUI。升级建议先备份 workflow、输出和自定义节点，再使用新卷，避免脚本静默覆盖已有环境。

## 自动部署的远端内容

- `/workspace/ComfyUI`；
- Anima Base v1 diffusion model；
- Qwen 3 0.6B text encoder；
- Qwen Image VAE；
- `/workspace/anima-project/workflows/original/image_anima_base_v1.json`；
- `/workspace/anima-project/records/anima-baseline.json`；
- Supervisor `comfyui` 服务；
- Codex CLI 和项目级 `.codex/config.toml`。

模型和 workflow 使用固定 URL；已配置 SHA-256 的文件会校验哈希，其他文件至少要求下载成功且非空。菜单中的“重新执行配置部署”会显示本地上传、源码检出、模型下载大小、校验、服务启动、健康检查和 Codex 配置进度。已验证的模型不会重复下载，下载中断后可从 `.part` 文件续传。部署结束前还会检查 ComfyUI 版本、CUDA、模型、workflow、Supervisor、健康接口及 Codex；菜单中的“查看部署状态”也会在实例运行时重复执行这组远端检查。

相关上游资料：

- [Vast.ai 创建 SSH key](https://docs.vast.ai/cli/reference/create-ssh-key)
- [Vast.ai 搜索报价](https://docs.vast.ai/cli/reference/search-instances)
- [Vast.ai 创建实例](https://docs.vast.ai/cli/reference/create-instance)
- [vastai/comfy Docker 镜像](https://hub.docker.com/r/vastai/comfy/)
- [Anima 官方模型卡](https://huggingface.co/circlestone-labs/Anima)
- [ComfyUI 官方 Anima workflow](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_anima_base_v1.json)

## 打开 ComfyUI

选择菜单中的“打开 ComfyUI SSH 隧道”，保持该终端运行，然后访问终端显示的地址：

- 预装 profile：`http://127.0.0.1:28188`
- 基础镜像 profile：`http://127.0.0.1:18188`

ComfyUI 在远端只监听 `127.0.0.1:18188`，不直接暴露到公网。关闭 SSH 隧道不会停止实例。

## Codex 登录

部署不会上传或持久化 OpenAI 凭据。SSH 登录实例后再运行：

```bash
/workspace/bin/codex-login.sh
/workspace/bin/run-codex.sh
```

默认使用设备码登录。认证文件位于实例容器的 root home，不放在 `/workspace` 持久卷中。

## 恢复和计费边界

- provision 失败时脚本不会自动销毁付费资源，以免误删数据；入口菜单会保留状态，可选择重试、停止或销毁；
- 卷已创建而实例创建失败时，卷 ID 仍写入 deployment state，可在销毁实例后单独删除；
- 新部署不会覆盖仍指向活动实例或保留卷的 state；
- Vast 本地卷绑定物理机器，不是跨机器高可用存储，重要输出仍应另行备份；
- 实例停止后恢复受原机器 GPU 可用性影响；
- 当前 Anima 模型卡标注非商业许可证，商业使用前应自行核对完整条款。

## 高级入口

`scripts/` 和 `profiles/vast-comfy/Invoke-Profile.ps1` 保留为调试与自动化构件。正常使用只运行 `Start-VastAnima.ps1`；直接调用底层带 `-Force` 的创建/销毁脚本会绕过统一入口的中文确认，不建议用于交互操作。

目录结构：

```text
vast-anima-deploy/
├── Start-VastAnima.ps1
├── config.psd1
├── user-config/
├── remote/
├── profiles/vast-comfy/
│   ├── config.psd1
│   ├── Invoke-Profile.ps1
│   ├── remote/provision.sh
│   └── state/
├── scripts/
│   ├── Initialize-Environment.ps1
│   ├── Initialize-SearchProfile.ps1
│   └── ...
└── state/
```
