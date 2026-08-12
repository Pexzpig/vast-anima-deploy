# Vast.ai PyTorch + Anima 自动部署

这套 PowerShell 脚本从 Windows 管理一套 Vast.ai 部署配置：搜索并选择 GPU、选择 ComfyUI 或 Forge Classic WebUI、选择持久卷或实例磁盘、创建实例、安装远端环境、下载 Anima 模型、配置 Codex，以及打开本机 SSH 隧道。

部署只使用一个固定基础镜像：

```text
vastai/pytorch:cuda-12.8.1-auto
```

不再提供 `vast-comfy`、`base-image` 或 profile 切换。应用不是由镜像预装，而是在实例创建后安装到 `/workspace`。脚本会先确认基础镜像的 Python、PyTorch、CUDA 运行时和实际 GPU 可用，再开始系统包、应用和模型安装。

## 开始使用

在 Windows PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd E:\Documents\img1\vast-anima-deploy
.\Start-VastAnima.ps1
```

首次运行会检查 Vast CLI、API key、SSH 密钥及账户公钥，然后初始化：

- 默认应用；
- GPU 型号、显存、CUDA、可靠度、网络速度和价格上限；
- 是否允许创建持久卷及卷大小。

生成的个人配置位于 `user-config/deployment.json`，运行状态位于 `state/deployment.json`，二者均被 Git 忽略。

主菜单：

```text
  1. 自动搜索并部署
  2. 查看符合条件的报价
  3. 查看部署状态
  4. 打开应用 SSH 隧道
  5. 重新执行配置部署
  6. 启动实例
  7. 停止实例
  8. 修改搜索参数
  9. 检查配置
 10. 销毁实例
 11. 永久删除持久卷
  0. 退出
```

第 9 项现在仅做配置检查，不再切换部署 profile。

## 部署流程

选择第 1 项后，脚本依次执行：

1. 选择 `ComfyUI` 或 `Forge Classic WebUI`；
2. 选择持久卷或仅使用实例磁盘；
3. 实时搜索 GPU，并显示每个报价的实例价格；
4. 由用户选择具体 GPU 报价；
5. 显示实例、卷和合计价格，输入 `RENT` 后才创建付费资源；
6. 等待 Vast 状态为 `running`，再持续探测 SSH，避免容器刚启动时上传失败；
7. 上传远端脚本并显示 11 个配置阶段、下载进度、服务日志和健康检查结果；
8. 验证 PyTorch/CUDA、Git checkout、应用虚拟环境、模型哈希、Supervisor、HTTP 健康接口及 Codex。

如果 SSH 在实例刚启动时暂时断开，上传步骤会自动重试。远端安装中断后可用第 5 项继续；已完成的 Git checkout、虚拟环境和模型文件会尽量复用，模型 `.part` 文件支持续传。

## PyTorch 和系统环境

远端配置首先运行基础镜像 Python，并要求：

- 可以导入 `torch`；
- `torch.cuda.is_available()` 为真；
- CUDA 运行时不低于配置中的 `12.8`；
- 可以读取当前 GPU 名称。

随后安装这些 Ubuntu 包：

```text
git ffmpeg libgl1 libglib2.0-0 wget curl aria2 tmux jq procps supervisor
```

并通过基础 Python 执行 `pip install -U uv`。ComfyUI 与 WebUI 使用各自位于 `/workspace/venvs/` 的虚拟环境，互不覆盖基础镜像环境。

## ComfyUI 配置

ComfyUI 安装到：

```text
/workspace/ComfyUI
/workspace/venvs/comfyui
```

脚本检出固定 `v0.28.0`，用基础 PyTorch 环境创建可访问系统包的独立 venv，再安装 `requirements.txt`。服务由 Supervisor 管理并只监听：

```text
127.0.0.1:18188
```

还会安装 Anima 模型、官方 workflow 和基线参数记录。打开菜单第 4 项后，在本机访问：

```text
http://127.0.0.1:28188
```

## Forge Classic WebUI 配置

WebUI 按 `Haoming02/sd-webui-forge-classic` 的 `neo` 分支配置：

```text
/workspace/sd-webui-forge-classic
/workspace/venvs/webui
```

脚本通过 `uv` 安装 Python 3.13、创建 venv，并准备：

```text
models/Stable-diffusion
models/text_encoder
models/VAE
```

Anima checkpoint、文本编码器和 VAE 会分别放入这些目录。第一次启动时 Forge 会继续安装它固定的 GPU 依赖，因此健康检查可能等待较久；进度和最新日志会持续显示。服务只监听远端 `127.0.0.1:17860`。打开菜单第 4 项后，在本机访问：

```text
http://127.0.0.1:27860
```

## 存储选择

每次新部署都可以选择：

- 持久卷：实例销毁后模型、输出和配置仍保留，但卷会继续计费，直到使用第 11 项永久删除；
- 实例磁盘：没有单独卷费，停止实例时文件保留，销毁实例时 `/workspace` 中的所有内容永久删除。

已经创建的实例不能原地更换镜像、应用类型或存储模式。要切换这些项目，必须先处理现有实例和卷，再创建新部署。

## 状态迁移

首次用新版入口运行时，如果只存在旧 `user-config/launcher.json` 和 `profiles/vast-comfy/state/deployment.json`，脚本会自动生成统一配置并复制旧状态，同时记录旧实例实际使用的镜像。它不会启动、停止、销毁或重复创建任何付费资源。

旧镜像实例不能原地转换为 `vastai/pytorch`。已完成配置的旧实例仍可查看和管理；创建新流程前，应先按需要备份并销毁旧实例、删除或保留旧卷。

## 远端 CLI 和 Codex

运行根目录辅助脚本：

```powershell
.\Open-VastRemoteCli.ps1
```

它会显示实际镜像、应用、价格、存储、SSH 地址、动态隧道端口和 Supervisor 检查命令，然后创建或恢复名为 `anima` 的 tmux 会话。仅查看信息而不进入 shell：

```powershell
.\Open-VastRemoteCli.ps1 -ShowOnly
```

实例已停止时，明确允许恢复计费并连接：

```powershell
.\Open-VastRemoteCli.ps1 -StartIfStopped
```

Codex 不会自动完成账户登录。进入 SSH 后运行：

```bash
/workspace/bin/codex-login.sh
/workspace/bin/run-codex.sh
```

## 常用非交互命令

```powershell
.\Start-VastAnima.ps1 -Action Search
.\Start-VastAnima.ps1 -Action Deploy
.\Start-VastAnima.ps1 -Action Status
.\Start-VastAnima.ps1 -Action Provision
.\Start-VastAnima.ps1 -Action Tunnel
.\Start-VastAnima.ps1 -Action Test
```

自动化调用时也可直接指定应用和存储：

```powershell
.\scripts\Deploy-Example.ps1 -ApplicationType WebUI -StorageMode InstanceDisk
```

## 本地测试

测试不会创建 Vast 资源：

```powershell
Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
}
```

## 上游项目

- [Vast.ai PyTorch 镜像](https://hub.docker.com/r/vastai/pytorch/)
- [Forge Classic WebUI](https://github.com/Haoming02/sd-webui-forge-classic)
- [Forge Classic WebUI Linux 安装说明](https://github.com/Haoming02/sd-webui-forge-classic/wiki/Unix)
- [Forge Classic WebUI 模型目录](https://github.com/Haoming02/sd-webui-forge-classic/wiki/Download-Models)
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI)
- [ComfyUI 官方 Anima workflow](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_anima_base_v1.json)
