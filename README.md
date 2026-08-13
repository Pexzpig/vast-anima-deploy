# Vast.ai Anima 自动部署

这套 PowerShell 脚本用于在 Windows 上管理 Vast.ai Anima 环境：搜索 GPU、创建实例、部署 ComfyUI 或 Forge Classic WebUI、下载模型、配置 Codex，并通过 SSH 隧道安全访问远端应用。

应用和模型安装在远端 `/workspace`。应用只监听远端 localhost，不直接暴露到公网。

## PowerShell 启动

在项目目录打开 Windows PowerShell。若系统禁止运行脚本，可仅为当前终端临时放行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

然后启动主菜单：

```powershell
cd C:\path\to\vast-anima-deploy
.\Start-VastAnima.ps1
```

首次运行会检查 PowerShell、Python、OpenSSH、Vast CLI/API 登录和 SSH 密钥，然后通过向导创建唯一配置：

```text
user-config/deployment.json
```

以后运行会直接读取该配置。主脚本每次开始操作前还会查询一次 Vast 账户实例，并刷新本地部署状态。

也可以跳过菜单，直接执行常用动作：

```powershell
.\Start-VastAnima.ps1 -Action Search          # 查看符合条件的 GPU 报价
.\Start-VastAnima.ps1 -Action Deploy          # 搜索并创建新部署，或继续中断的部署
.\Start-VastAnima.ps1 -Action Status          # 查看并对账当前状态
.\Start-VastAnima.ps1 -Action Provision       # 重新执行远端配置
.\Start-VastAnima.ps1 -Action Tunnel          # 打开应用 SSH 隧道
.\Start-VastAnima.ps1 -Action Start           # 启动实例
.\Start-VastAnima.ps1 -Action Stop            # 停止实例
.\Start-VastAnima.ps1 -Action Configure       # 修改搜索和部署选项
.\Start-VastAnima.ps1 -Action Test            # 检查配置
.\Start-VastAnima.ps1 -Action ConnectExisting # 连接其他环境创建的脚本实例
.\Start-VastAnima.ps1 -Action Destroy         # 永久销毁实例
.\Start-VastAnima.ps1 -Action RemoveVolume    # 永久删除独立持久卷
```

如果从浏览器下载的项目仍被 Windows 标记为来自网络，也可以先执行：

```powershell
Get-ChildItem -Recurse -File | Unblock-File
```

## 脚本运行流程

选择“自动搜索并部署”后，脚本按以下顺序工作：

1. 选择 ComfyUI 或 Forge Classic WebUI，以及持久卷或实例磁盘。
2. 按配置实时搜索 GPU，显示 GPU、显存、地区、IP、可靠度、带宽和价格。
3. 显示实例、可选持久卷及合计价格；只有输入 `RENT` 才会创建付费资源。
4. 立即保存本地状态，创建卷和实例，并等待 Vast 状态及 SSH 服务就绪。
5. 生成远端配置，上传部署脚本，通过 SSH 执行安装。
6. 安装应用环境，下载并校验模型、Turbo LoRA 和配置中启用的 LoRA。
7. 为 ComfyUI 生成标准与高清工作流，或为 WebUI 安装 Tag Autocomplete 和简体中文扩展。
8. 配置 Supervisor、等待应用健康接口，并安装 Codex CLI。
9. 完成 GPU、模型、工作流或扩展、服务和健康接口检查后，将部署标记为完成。

若网络或 SSH 中断，可再次执行 `Deploy` 或 `Provision`。脚本会复用已经创建的卷、实例、Git 仓库、虚拟环境和模型下载临时文件，不会在已有活动资源时重复租用。

## 配置与状态

项目使用以下本地文件，它们均被 Git 忽略：

```text
user-config/deployment.json   # 应用、GPU 搜索、模型、SSH 和 Codex 配置
state/deployment.json         # 本机创建的实例、卷和部署进度
state/attached-instance.json  # 跨环境连接记录，可选
```

`config.psd1` 是首次初始化和新增配置项的模板。“修改搜索参数”只更新向导负责的选项，并补充缺失的新字段；不会覆盖端口、模型、SSH、远端路径或其他现有自定义配置。

旧安装遗留的 `user-config/launcher.json`、`user-config/vast-comfy.json` 等文件不再被读取或迁移，可在确认无用后自行删除。

## ComfyUI

部署后通过主菜单“打开应用 SSH 隧道”访问：

```text
本地地址：http://127.0.0.1:28188
应用目录：/workspace/ComfyUI
LoRA 目录：/workspace/ComfyUI/models/loras
标准工作流：image_anima_base_v1.managed.json
高清工作流：image_anima_base_v1.hires.managed.json
```

标准工作流默认使用 Anima Base。需要快速预览时打开顶层 `turbo_mode`，会同时切换到 Turbo LoRA、8 steps 和 CFG 1。

高清工作流先按 Base 参数生成，再进行 latent 放大和低降噪二次采样。默认倍率为 1.5、denoise 为 0.35；提高倍率会增加显存、耗时以及构图漂移风险。

角色和画风 LoRA 有两种用法：

- 在 `Anima.ManagedLoRAs` 中配置公开 HTTPS 地址和 SHA-256，由部署脚本下载并按配置顺序应用。
- 手动上传到 `/workspace/ComfyUI/models/loras`，然后在工作流顶部的角色或画风槽位选择文件并设置权重；两个槽位默认权重为 0。

重新执行 provision 会重建托管工作流。需要长期保留的手工修改，应在 ComfyUI 中另存为个人工作流。第三方 LoRA 应确认兼容 Anima Base，并自行核对触发词及许可。Anima 模型的使用范围以其官方非商业模型许可证为准。

## Forge Classic WebUI

部署后通过主菜单“打开应用 SSH 隧道”访问：

```text
本地地址：http://127.0.0.1:27860
应用目录：/workspace/sd-webui-forge-classic
```

脚本自动安装并启用：

- Tag Autocomplete；
- 简体中文本地化。

重新执行 provision 会校正这两个托管扩展和中文配置，但不会删除用户自行安装的其他扩展。

## 连接其他环境创建的实例

使用主菜单“连接账户已有脚本实例”，或运行：

```powershell
.\Start-VastAnima.ps1 -Action ConnectExisting
.\scripts\Connect-VastExistingInstance.ps1 -Mode Shell
.\scripts\Connect-VastExistingInstance.ps1 -Mode Tunnel
```

该功能只列出同一 Vast 账户中、标签匹配并通过远端部署标记与健康检查的实例。当前电脑必须持有该实例接受的 SSH 私钥。

连接记录不会覆盖本机 `state/deployment.json`。附加实例只允许打开 SSH/tmux 或应用隧道，不能通过该入口 provision、停止、销毁或管理卷。若选择启动停止中的实例，需要明确确认恢复 GPU 计费。

## 日常运维与恢复

打开远端终端：

```powershell
.\Open-VastRemoteCli.ps1
.\Open-VastRemoteCli.ps1 -ShowOnly
.\Open-VastRemoteCli.ps1 -StartIfStopped
```

远端 Codex 登录与启动：

```bash
/workspace/bin/codex-login.sh
/workspace/bin/run-codex.sh
```

脚本支持以下恢复情况：

- 卷已创建但实例创建失败：复用原卷，并限制到原机器重新搜索。
- 实例已创建但部署未完成：继续等待、上传和安装，不重复租用。
- SSH 或下载暂时中断：自动重试；模型 `.part` 文件可继续下载。
- 实例在 Vast 网页端被删除：下次状态对账会将本地实例标记为已销毁。
- 配置镜像与已有实例不一致：拒绝继续部署，防止错误套用配置。

## 停止、销毁与计费

- `Stop` 停止 GPU 计算计费，但实例磁盘或独立持久卷仍可能产生存储费用。
- `Destroy` 永久销毁实例，实例磁盘中的应用、模型和输出随之丢失。
- 独立持久卷不会随实例自动删除，需在实例销毁后单独执行 `RemoveVolume`。
- 创建实例、销毁实例和删除卷都要求明确确认。
- 本地状态中存在活动实例或卷时，会阻止再次创建付费资源，支持的中断恢复情况除外。

## 上游项目

- [Vast.ai PyTorch 镜像](https://hub.docker.com/r/vastai/pytorch/)
- [Forge Classic WebUI](https://github.com/Haoming02/sd-webui-forge-classic)
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI)
- [Anima](https://huggingface.co/circlestone-labs/Anima)
- [SD WebUI Tag Autocomplete](https://github.com/DominikDoom/a1111-sd-webui-tagcomplete)
- [SD WebUI 简体中文本地化](https://github.com/dtlnor/stable-diffusion-webui-localization-zh_CN)
