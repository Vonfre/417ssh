# 417ssh Windows

这是 `417ssh` 的 Windows 版本，界面结构和功能尽量贴近 macOS 版：

- 保存多组 Jupyter / RStudio / 终端 / SFTP 工作区配置。
- 配置窗口内置快捷填写区，可以直接粘贴 `ssh ...` 命令并自动填入目标主机、跳板机、端口转发、压缩、详细日志和密钥路径。
- 新增配置可以直接取消，取消后不会留下空白连接。
- 支持目标机、跳板机、密码、密钥、SSH keepalive。
- 建立 Jupyter 或 RStudio Server 本地端口转发，并在应用内嵌浏览器打开 `http://127.0.0.1:<端口>/<路径>`。
- 提供内置真实 SSH 终端：界面使用随应用打包的 xterm.js 终端模拟器，后端连接 Paramiko SSH PTY；也可以打开 Windows 原生 `cmd.exe` 里的 `ssh`。
- 终端工作区可以点击 `文件` 展开 SFTP 侧栏；侧栏支持将 `cd <SFTP 路径>` 放到终端、同步到终端当前文件夹、自动跟随终端 `cd` 切换；目录跳转会先即时切换路径并在后台刷新列表，文件列表支持点击表头排序。
- 终端目录同步会保留点号、下划线、空格、括号和中文等路径字符，避免 `/ceph/zhanghuan/2.docker` 这类目录被截断；路径同步按钮使用和 macOS 对应的图标按钮。
- 纯 SFTP 工作区只保留一个入口；进入后顶部标签可多开多个传输组合，每个标签内部固定为左右 A/B 两栏，左侧默认 `127.0.0.1`，两栏都可从 Hosts 页面选择本地、终端工作区或自定义 SFTP 来源。
- 浏览本地和远程目录、返回上级、筛选、本地拖到远程上传、远程拖到本地下载、A/B 两栏间远程传输、按钮上传文件/文件夹、下载文件/文件夹；文件列表使用文件/文件夹图标；自定义 SFTP Host 在 Hosts 区用按钮新增、编辑和删除。
- 文件列表支持右键操作：打开、下载、复制到目标目录、重命名、删除、新建文件夹和修改权限。

## 下载使用

打开 [GitHub Releases](https://github.com/Vonfre/417ssh/releases)，下载：

```text
417ssh-<版本>-win-portable.zip
```

解压后进入 `417ssh` 文件夹，双击 `417ssh.exe` 运行。请保持 `417ssh.exe` 和 `_internal` 文件夹在一起，不要只移动 exe。portable 版本不需要用户安装 Python。

配置保存在：

```text
%APPDATA%\417ssh\profiles.json
```

如果 Windows SmartScreen 提示未知发布者，选择 `更多信息` 后继续运行。正式分发时建议后续补代码签名。

## 源码运行

先安装 Windows 版 Python 3.10+，然后双击：

```bat
run_windows.bat
```

脚本会安装运行依赖并启动程序。

## 打包 exe

推荐使用仓库根目录的 GitHub Actions workflow `Build Release Packages` 生成并上传 portable zip。

本地调试 exe：

```powershell
.\build_windows.ps1
```

生成文件夹：

```text
dist\417ssh\417ssh.exe
```

## 打包 portable zip

```powershell
.\build_portable.ps1
```

生成文件：

```text
dist\417ssh-<版本>-win-portable.zip
```

## 说明

- Windows 版使用 Paramiko 连接 SSH，所以内置网页隧道、内置 xterm.js 终端和 SFTP 都支持密码登录。
- Jupyter/RStudio 页面优先使用 Qt WebEngine 内嵌在窗口里；如果当前 Python 环境没有 WebEngine，会回退到系统默认浏览器。
- “原生终端”调用 Windows 自带 OpenSSH 的 `ssh` 命令；如果用密码登录，需要在弹出的终端里手动输入密码。
- 如果要使用密钥，请在配置里填写 Windows 路径，例如 `C:\Users\you\.ssh\id_ed25519`。
- 连接配置只保存在 `%APPDATA%\417ssh\profiles.json`，不会写入 GitHub 仓库或发布包。
- `src\417ssh_qt.py` 是当前 Windows 图形界面入口；`src\417ssh_windows.py` 保留共享的配置、SSH、隧道和 Paramiko 连接逻辑。
- 切换工作区会保留已连接的 Jupyter/RStudio 隧道、终端和 SFTP 文件浏览状态，终端 SFTP 侧栏的路径、列表、筛选和缓存会按连接分别保存。
- SFTP 会按连接配置复用 SSH 连接；多个 SFTP 标签可以同时连接不同服务器，同一个服务器的连续目录和文件操作会复用连接。
- 设置里可以检查 GitHub Releases 更新；检测到新版本后会下载 portable `.zip`，在后台自动解压、替换当前 portable 文件夹并重启，不会弹出命令行窗口。
- Windows 自动更新会先备份当前 portable 文件夹；如果替换失败，会尝试回滚并重启原版本。
- `0.4.5` 之前的旧版更新器可能会弹出 `find "<PID>"` 命令行并中断更新；从这些旧版本升级时请手动下载新版 zip 覆盖一次，之后再使用设置里的自动更新。
- 发布新版本时，release asset 使用 `417ssh-<版本>-win-portable.zip` 命名。
