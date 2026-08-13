# Vast.ai PyTorch + Anima 自动部署

这套 PowerShell 脚本从 Windows 管理一套 Vast.ai Anima 部署：选择 ComfyUI 或 Forge Classic WebUI、搜索 GPU、选择持久卷或实例磁盘、创建实例、安装远端环境、下载并校验模型、配置 Codex，以及通过 SSH 隧道访问应用。

部署固定使用以下基础镜像：

```text
vastai/pytorch:cuda-12.8.1-auto
```

应用和模型安装在 `/workspace`，服务只监听远端 localhost，不直接暴露到公网。

## 快速开始

在 Windows PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd E:\Documents\img1\vast-anima-deploy
.\Start-VastAnima.ps1
```

项目只使用一份 canonical 用户配置和一份部署状态；跨环境连接另有可选的独立记录：

```text
user-config/deployment.json   # 搜索、实例、应用、模型、SSH 和 Codex 配置
state/deployment.json         # 当前实例/卷及部署进度
state/attached-instance.json  # 可选的跨环境只读连接记录
```

这些 JSON 均被 Git 忽略。`config.psd1` 是首次初始化的模板，不是日常部署状态。附加实例记录与部署状态完全独立，不拥有远端资源生命周期权限。

## 首次初始化

入口脚本首先完成本地环境检查：

1. 检查 PowerShell、OpenSSH、Python 和 Vast CLI；
2. Vast CLI 缺失时，经用户确认后通过 pip 安装；
3. 实时验证 Vast API 身份，未登录时引导设置 API key；
4. 检查 SSH 私钥与公钥是否匹配，必要时创建 Ed25519 key；
5. 检查 Vast 账户公钥，必要时注册并再次验证；
6. 运行四页参数向导并创建 `user-config/deployment.json`。

环境检查后、执行菜单或指定 `-Action` 前，入口会调用一次 `vastai show instances --raw` 查询账户现有实例，并将本地 `state/deployment.json` 跟踪实例的实时状态写回 state；状态未变化时也会更新时间戳，以记录本次对账。远端实例已经不存在时，本地状态更新为 `destroyed`；没有本地部署状态时只查询账户，不创建 state。

向导管理以下字段：

- 默认应用；
- GPU 型号、最低显存、CUDA、可靠度和下载速度；
- 实例每小时价格上限和搜索结果数量；
- 是否允许创建持久卷及卷大小。

以后使用菜单“修改搜索参数”时，会基于现有配置修改这些字段。Codex、端口、仓库、模型、SSH 和远端路径等其他自定义值不会被模板覆盖。版本新增的 WebUI 固定提交、PyTorch/CUDA 版本、扩展和工作流校验字段只在缺失时由模板补入；旧版默认的可变工作流 URL 会一并收敛到固定提交。自定义工作流 URL 不会被覆盖，但必须由用户填写与其内容匹配的 SHA-256 才能通过配置检查。

## 新建部署流程

主菜单选择“自动搜索并部署”后：

1. 选择 `ComfyUI` 或 `Forge Classic WebUI`；
2. 选择独立持久卷或仅使用实例磁盘；
3. 使用当前配置实时搜索 Vast GPU 报价；
4. 显示型号、显存、可靠度、下载速度、IP、地区和实例时价，由用户选择报价；
5. 持久卷模式额外检查所选物理机器上的卷报价；
6. 显示实例价格、卷月价和估算合计时价；
7. 只有准确输入 `RENT` 才写入初始 state 并创建付费资源；
8. 创建可选持久卷和实例，等待 Vast 状态变为 `running`；
9. 解析实时 SSH 地址并持续探测，直到 SSH 服务稳定；
10. 自动进入远端配置和验证流程。

实例磁盘模式不会调用 `create volume`，也不会添加 `--link-volume`。停止实例会保留实例磁盘；销毁实例会永久删除其中的应用、模型、配置和输出。

持久卷挂载到 `/workspace`。销毁实例不会自动删除独立卷，卷会继续计费，直到主菜单中单独执行“永久删除持久卷”。

## 配置与验证阶段

本地 provision 共 5 个阶段：

1. 等待实例并解析 SSH endpoint；
2. 生成严格的远端 JSON 配置；
3. 上传 provision、Codex、验证脚本和配置；
4. 通过 SSH 执行远端安装；
5. 验证成功后更新本地 state。

远端 provision 共 11 个阶段：

1. 定位并验证基础 PyTorch 环境；
2. 安装 Ubuntu 系统包；
3. 安装 `uv` 并准备 `/workspace`；
4. 检出并准备所选应用；
5. 验证应用 Python/GPU 环境；
6. 下载并校验 Anima 模型；
7. 根据基线参数生成 ComfyUI 托管 workflow，或安装并配置 WebUI 扩展；
8. 配置 Supervisor 服务和重启恢复；
9. 等待应用健康接口；
10. 安装并配置 Codex CLI；
11. 执行完整部署验证。

完整验证包括：

- 基础 PyTorch 可导入、CUDA 可用且版本不低于 `12.8`；
- Git checkout 与固定 ref 一致；
- 应用 Python 环境可以访问 GPU；
- 三个 Anima 模型存在且 SHA-256 正确；
- ComfyUI 原始 workflow 哈希及托管 workflow 参数正确，或 WebUI 扩展提交与中文配置正确；
- Supervisor 服务为 `RUNNING`；
- 应用 HTTP 健康接口可访问；
- Codex CLI、项目配置和登录辅助脚本存在。

## 应用与隧道

ComfyUI：

```text
应用目录：/workspace/ComfyUI
虚拟环境：/workspace/venvs/comfyui
远端监听：127.0.0.1:18188
本地地址：http://127.0.0.1:28188
固定版本：v0.28.0
托管工作流：image_anima_base_v1.managed.json
```

官方 Anima 工作流固定到提交 `12199d938df3c531853036116c145286790a7be7`。部署保留原始文件，再根据 `Anima.Baseline` 写入宽高、提示词、固定 seed、steps、CFG、sampler 和 scheduler。托管副本使用基础模式，不启用 Turbo LoRA；重复 provision 会按当前配置重新生成。

Forge Classic WebUI：

```text
应用目录：/workspace/sd-webui-forge-classic
虚拟环境：/workspace/venvs/webui
远端监听：127.0.0.1:17860
本地地址：http://127.0.0.1:27860
仓库/来源分支：Haoming02/sd-webui-forge-classic / neo
固定发布提交：6e8086edeaef473eb05b48b55518802fadf5bba1（2.24）
Python：3.13
PyTorch：2.11.0 + CUDA 12.8
Torchvision：0.26.0
```

WebUI 首次启动前自动安装以下固定扩展：

- Tag Autocomplete：`8766965a305b09aee4aa65aa754f84feaf801437`；
- 简体中文本地化：`3b310d9c72c78264ab37d7651ab2638945e28dd8`。

全新安装时，脚本先让 Forge 创建带当前 `VERSION_UID` 的 `config.json`，随后合并语言和扩展设置并自动重启一次，避免被 Forge 误判为旧版配置。后续 provision 直接合并现有配置：保留其他设置，将语言设为 `zh_CN`，并确保两个托管扩展未被禁用。用户自行安装的其他扩展不会被删除。若早期脚本已经生成了缺少版本标记的最小配置，重试时会先将其备份到 `/workspace/anima-project/records/` 再自动恢复部署。

WebUI 主仓库不会跟随 `neo` 滚动更新。每次 provision 都强制检出上述固定提交，并在启动前校验受管 venv 的 Python、Torch、Torchvision、CUDA runtime 和 GPU 可用性；不匹配时只重建 `/workspace/venvs/webui`，不会删除模型、输出或用户扩展。Supervisor 启动脚本同时固定 `TORCH_COMMAND` 到官方 cu128 wheel index，防止 Forge 自行换回 CUDA 13 构建。

主菜单选择“打开应用 SSH 隧道”，保持终端窗口打开，再访问对应本地地址。

## 连接其他环境创建的实例

主菜单选择“连接账户已有脚本实例”，或运行：

```powershell
.\Start-VastAnima.ps1 -Action ConnectExisting
.\scripts\Connect-VastExistingInstance.ps1 -Mode Shell
.\scripts\Connect-VastExistingInstance.ps1 -Mode Tunnel
```

该流程查询当前 Vast 登录账户，只显示标签与 `Vast.Instance.Label` 一致的实例；选择表显示状态、GPU、镜像、地区、IP 和价格，不显示实例 ID。选中后还必须通过 SSH 验证远端 `vast-anima-deploy` manifest；当前版本以前创建的实例则必须保留上传配置、应用记录和验证脚本，并现场通过完整健康验证。

停止中的实例需要输入 `START` 才会启动并恢复 GPU 计费。如果本次启动后 SSH、密钥或远端标记验证失败，脚本会尝试把实例恢复为停止状态。当前机器必须持有实例接受的 SSH 私钥；Vast 账户相同并不代表新生成的私钥可以登录旧实例。

验证成功后只写入 `state/attached-instance.json`，用于下次快速重连。附加实例仅支持 SSH/tmux 和应用隧道，不会进入本地 `deployment.json`，也不能通过该入口停止、provision、销毁或管理卷。本机自己的 canonical deployment 可以同时存在。

## 中断恢复与日常运维

新版 state 使用严格的 `schema_version = 2`，并记录应用、镜像、存储方式和完整资源生命周期。字段缺失或版本不符会明确报错，不会推断或改写状态。

当前版本保留以下安全恢复行为：

- 卷已创建但实例创建失败：再次部署时复用原卷，并只搜索该卷所在机器的 GPU；
- 实例已创建但尚未 provision：再次部署时继续等待、上传和安装，不会重复租用；
- SSH 暂时不可用：上传步骤自动重试；
- 远端安装中断：复用 Git checkout 和虚拟环境，模型 `.part` 文件继续下载；
- 网页端删除实例：查看状态或销毁时与账户对账，将本地状态标记为 `destroyed`；
- 配置镜像与现有实例记录不一致：拒绝 provision，防止把不同镜像配置套到已创建实例。

常用动作：

```powershell
.\Start-VastAnima.ps1 -Action Search
.\Start-VastAnima.ps1 -Action Deploy
.\Start-VastAnima.ps1 -Action Status
.\Start-VastAnima.ps1 -Action Provision
.\Start-VastAnima.ps1 -Action Tunnel
.\Start-VastAnima.ps1 -Action Start
.\Start-VastAnima.ps1 -Action Stop
.\Start-VastAnima.ps1 -Action Destroy
.\Start-VastAnima.ps1 -Action RemoveVolume
.\Start-VastAnima.ps1 -Action Configure
.\Start-VastAnima.ps1 -Action Test
.\Start-VastAnima.ps1 -Action ConnectExisting
```

打开远端交互式 shell：

```powershell
.\Open-VastRemoteCli.ps1
.\Open-VastRemoteCli.ps1 -ShowOnly
.\Open-VastRemoteCli.ps1 -StartIfStopped
```

该脚本默认读取唯一用户配置。显式 `-ConfigPath` 仅用于测试或高级诊断。

远端 Codex 登录和启动：

```bash
/workspace/bin/codex-login.sh
/workspace/bin/run-codex.sh
```

## 销毁与计费边界

- `Stop` 停止 GPU 计算计费，但实例磁盘或独立卷仍可能产生存储费用；
- `Destroy` 永久销毁实例；实例磁盘数据随之丢失；
- `RemoveVolume` 只能在关联实例销毁后执行，并永久删除模型和输出；
- 创建实例、销毁实例和删除卷分别要求明确确认；
- state 中存在活动实例或卷时，新部署会被阻止，除非属于受支持的中断恢复状态。

## 历史遗留本地文件

旧安装可能仍在 ignored 目录中保留 `user-config/launcher.json`、`user-config/vast-comfy.json` 等 JSON。当前代码完全不读取、不迁移、也不自动删除这些文件；确认不再需要后可由用户自行清理。

## 本地测试

测试不会创建 Vast 付费资源：

```powershell
Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
}
```

## 上游项目

- [Vast.ai PyTorch 镜像](https://hub.docker.com/r/vastai/pytorch/)
- [Forge Classic WebUI](https://github.com/Haoming02/sd-webui-forge-classic)
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI)
- [ComfyUI 官方 Anima workflow](https://github.com/Comfy-Org/workflow_templates/blob/12199d938df3c531853036116c145286790a7be7/templates/image_anima_base_v1.json)
- [SD WebUI Tag Autocomplete](https://github.com/DominikDoom/a1111-sd-webui-tagcomplete)
- [SD WebUI 简体中文本地化](https://github.com/dtlnor/stable-diffusion-webui-localization-zh_CN)
