# 417ssh Windows

这是 `417ssh` 的 Windows 版本，界面结构和功能尽量贴近 macOS 版：

- 保存多组 Jupyter / 终端工作区配置。
- 支持目标机、跳板机、密码、密钥、SSH keepalive。
- 建立 Jupyter 本地端口转发，并在应用内嵌浏览器打开 `http://127.0.0.1:<端口>/<路径>`。
- 提供简易内置 SSH 终端，也可以打开 Windows 原生 `cmd.exe` 里的 `ssh`。
- 浏览远程目录、返回上级、筛选、拖拽上传、按钮上传文件/文件夹、下载文件/文件夹。

## 运行

先安装 Windows 版 Python 3.10+，然后双击：

```bat
run_windows.bat
```

脚本会安装运行依赖并启动程序。配置保存在：

```text
%APPDATA%\417ssh\profiles.json
```

## 打包 exe

推荐使用仓库根目录的 GitHub Actions workflow `Build Release Installers` 生成并上传 MSI。

本地调试 exe：

在 PowerShell 里运行：

```powershell
.\build_windows.ps1
```

生成文件：

```text
dist\417ssh.exe
```

## 打包 MSI

先安装 WiX Toolset v4：

```powershell
winget install WiXToolset.WiXToolset
```

然后运行：

```powershell
.\build_msi.ps1
```

生成文件：

```text
dist\417ssh-0.2.2-win.msi
```

## 说明

- Windows 版使用 Paramiko 连接 SSH，所以内置 Jupyter 隧道、内置终端和 SFTP 都支持密码登录。
- Jupyter 页面优先使用 Qt WebEngine 内嵌在窗口里；如果当前 Python 环境没有 WebEngine，会回退到系统默认浏览器。
- “原生终端”调用 Windows 自带 OpenSSH 的 `ssh` 命令；如果用密码登录，需要在弹出的终端里手动输入密码。
- 如果要使用密钥，请在配置里填写 Windows 路径，例如 `C:\Users\you\.ssh\id_ed25519`。
- `src\417ssh_windows.py` 是早期 Tkinter 版本，默认入口已经切换到更接近 macOS UI 的 `src\417ssh_qt.py`。
- 设置里可以检查 GitHub Releases 更新；检测到新版本后会下载 `.msi` 并启动安装器。
- 发布新版本时，建议 release asset 使用 `417ssh-<版本>-win.msi` 命名。
