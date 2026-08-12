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

项目只使用一份用户配置和一份运行状态：

```text
user-config/deployment.json   # 搜索、实例、应用、模型、SSH 和 Codex 配置
state/deployment.json         # 当前实例/卷及部署进度
```

两者均被 Git 忽略。`config.psd1` 是首次初始化的模板，不是日常部署状态。

## 首次初始化

入口脚本首先完成本地环境检查：

1. 检查 PowerShell、OpenSSH、Python 和 Vast CLI；
2. Vast CLI 缺失时，经用户确认后通过 pip 安装；
3. 实时验证 Vast API 身份，未登录时引导设置 API key；
4. 检查 SSH 私钥与公钥是否匹配，必要时创建 Ed25519 key；
5. 检查 Vast 账户公钥，必要时注册并再次验证；
6. 运行四页参数向导并创建 `user-config/deployment.json`。

向导管理以下字段：

- 默认应用；
- GPU 型号、最低显存、CUDA、可靠度和下载速度；
- 实例每小时价格上限和搜索结果数量；
- 是否允许创建持久卷及卷大小。

以后使用菜单“修改搜索参数”时，会基于现有配置修改这些字段。Codex、端口、仓库、模型、SSH 和远端路径等其他自定义值不会被模板覆盖。

## 新建部署流程

主菜单选择“自动搜索并部署”后：

1. 选择 `ComfyUI` 或 `Forge Classic WebUI`；
2. 选择独立持久卷或仅使用实例磁盘；
3. 使用当前配置实时搜索 Vast GPU 报价；
4. 显示型号、显存、可靠度、下载速度、机器 ID 和实例时价，由用户选择报价；
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
7. 安装 workflow 或基线配置；
8. 配置 Supervisor 服务和重启恢复；
9. 等待应用健康接口；
10. 安装并配置 Codex CLI；
11. 执行完整部署验证。

完整验证包括：

- 基础 PyTorch 可导入、CUDA 可用且版本不低于 `12.8`；
- Git checkout 与固定 ref 一致；
- 应用 Python 环境可以访问 GPU；
- 三个 Anima 模型存在且 SHA-256 正确；
- ComfyUI workflow 或 WebUI 基线记录存在；
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
```

Forge Classic WebUI：

```text
应用目录：/workspace/sd-webui-forge-classic
虚拟环境：/workspace/venvs/webui
远端监听：127.0.0.1:17860
本地地址：http://127.0.0.1:27860
仓库/分支：Haoming02/sd-webui-forge-classic / neo
```

主菜单选择“打开应用 SSH 隧道”，保持终端窗口打开，再访问对应本地地址。

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
- [ComfyUI 官方 Anima workflow](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_anima_base_v1.json)
