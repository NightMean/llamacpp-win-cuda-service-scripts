# llamacpp-win-cuda-service-scripts

[English](README.md) | 中文

Windows PowerShell 脚本，用于自动下载、更新、切换并运行本地
[llama.cpp](https://github.com/ggml-org/llama.cpp) Windows CUDA 版
`llama-server`。

本仓库只包含脚本和示例配置，不包含下载后的 llama.cpp 二进制、CUDA 运行时、
模型文件、日志、运行状态或私人 token。

## 功能

- 检查 `ggml-org/llama.cpp` 在 GitHub 上的最新 release。
- 选择最新匹配的 Windows x64 CUDA 主程序包和 CUDA runtime 包。
- 在 GitHub 提供 SHA-256 digest 时，下载并校验 release 压缩包。
- 将选中的版本安装到本地带版本号的目录。
- 将 `llama-current` 切换到当前启用的安装目录。
- 启动、停止并检查本地 `llama-server`。
- 保留少量旧版本和缓存压缩包，方便回滚。

## 环境要求

- Windows PowerShell。
- Windows 系统、NVIDIA GPU，以及兼容所选 CUDA build 的驱动。
- 能访问 GitHub releases 的网络环境。
- 本地 GGUF 模型文件。
- 可选：GitHub CLI，或 `GITHUB_TOKEN`/`GH_TOKEN` 环境变量，用于避免 GitHub API
  未认证请求限流。

## 快速开始

1. 克隆本仓库。
2. 复制 `llama-config/models.example.ini` 为 `llama-config/models.ini`。
3. 编辑 `llama-config/models.ini`，把 `model = ...` 指向你的本地 GGUF 文件。
4. 可选：设置 `GITHUB_TOKEN` 或 `GH_TOKEN` 环境变量。如果你更想用本地文件，可以
   复制 `llama-config/github-token.example.txt` 为
   `llama-config/github-token.txt`，再把 token 写进去。
5. 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\update-llamacpp-cuda13.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\start-llamacpp-server.ps1
```

默认服务地址是 `http://127.0.0.1:8080`。
监听地址和端口统一读取自 `llama-config/models.ini` 的 `[*]` 段；更换设备或端口时
不需要修改启动、停止或更新脚本。

若要让服务器在 Windows 启动后自动运行（即使用户尚未登录），请在管理员
PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\register-start-task-at-startup.ps1
```

如果名为 `Start llama.cpp server` 的任务不存在，该命令会直接创建；仅当同名任务
已经存在时才会覆盖。任务默认在系统启动 30 秒后运行，可通过 `-DelaySeconds`
调整延迟。仓库可以位于任意目录，脚本会根据自身位置确定项目路径。

该任务使用 S4U 实现无需登录运行。Windows 不会为它保存账户密码，但 S4U 任务不能
访问网络共享或 EFS 加密文件；请将仓库、配置和 GGUF 模型放在本地可访问路径中。

## 脚本

- `llama-scripts/update-llamacpp-cuda13.ps1`：下载、安装、切换、重启，并清理旧
  版本。
- `llama-scripts/start-llamacpp-server.ps1`：使用本地 models preset 启动
  `llama-server`。
- `llama-scripts/stop-llamacpp-server.ps1`：卸载已加载模型并停止 server 进程。
- `llama-scripts/restart-llamacpp-server.ps1`：先停止再启动 server，用于让
  `llama-config/models.ini` 修改生效。
- `llama-scripts/check-llamacpp-version.ps1`：比较本地启用版本和上游最新 release。
- `llama-scripts/register-start-task-at-startup.ps1`：注册无需用户登录的 Windows
  开机启动任务；新设备上直接创建，存在同名旧任务时将其替换。
- `llama-scripts/register-update-task-run-logged-off.ps1`：注册周期更新的 Windows
  计划任务；新设备上直接创建，存在同名旧任务时将其替换。
- `llama-scripts/test-llama-scripts.ps1`：运行轻量脚本测试。

## 配置

私有配置文件是 `llama-config/models.ini`。它通常包含本机模型路径，所以已被 Git
忽略。

私有 token 文件是 `llama-config/github-token.txt`，也已被 Git 忽略。更推荐使用
环境变量：

```powershell
$env:GITHUB_TOKEN = "your_token_here"
```

## 仓库安全

`.gitignore` 会排除：

- `llama-config/github-token.txt`
- `llama-config/models.ini`
- 下载后的 llama.cpp/CUDA 二进制文件
- 下载缓存压缩包
- 日志和运行时 pid 文件
- `llama-current` junction

不要提交模型文件、CUDA DLL、release ZIP、日志或本地 token。

## 许可证

本仓库中的脚本使用 MIT License 发布。下载后的 llama.cpp artifacts 仍遵循其上游
许可证，CUDA runtime 组件受 NVIDIA 许可条款约束。
