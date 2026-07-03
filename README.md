# 417ssh

[![Build Release Packages](https://github.com/Vonfre/417ssh/actions/workflows/release.yml/badge.svg)](https://github.com/Vonfre/417ssh/actions/workflows/release.yml)

`417ssh` 是一个面向 SSH / Jupyter / RStudio Server / SFTP 日常工作的桌面工具。它把常用的远程连接、网页服务端口转发、终端和文件传输放在同一个界面里，适合经常通过跳板机连接服务器、打开 Jupyter Lab 或 RStudio Server、上传下载文件的工作流。

## 下载

普通用户请打开 [GitHub Releases](https://github.com/Vonfre/417ssh/releases) 下载成品包。

| 平台 | 下载文件 | 使用方式 |
| --- | --- | --- |
| macOS | `417ssh-<版本>-mac-app.zip` | 解压后运行 `417ssh.app` |
| Windows | `417ssh-<版本>-win-portable.zip` | 解压后运行 `417ssh.exe` |

不要点击 GitHub 的 `Code -> Download ZIP` 当作应用下载。那个 zip 是源码包，不能直接当桌面应用运行。

## 快速开始

### macOS

1. 下载 `417ssh-<版本>-mac-app.zip`。
2. 解压得到 `417ssh.app` 和 `README-macOS.txt`。
3. 双击运行，或拖到 `Applications` 后运行。
4. 如果 macOS 提示“Apple 无法验证”，先点“完成”，不要点“移到废纸篓”；然后在 Finder 里右键 `417ssh.app`，选择 `打开`。

macOS 版本使用系统自带的 `/usr/bin/ssh` 建立隧道和终端连接。

### Windows

1. 下载 `417ssh-<版本>-win-portable.zip`。
2. 解压后进入 `417ssh` 文件夹。
3. 双击 `417ssh.exe` 运行。

Windows portable 版本不需要安装 Python。配置文件保存在：

```text
%APPDATA%\417ssh\profiles.json
```

如果 Windows SmartScreen 提示未知发布者，选择 `更多信息` 后继续运行。正式分发时后续可以补代码签名来减少这个提示。

## 功能

- 保存多组 SSH / Jupyter / RStudio / 终端工作区配置。
- 配置窗口内置快捷填写区，可以直接粘贴 `ssh ...` 命令并自动填入目标主机、跳板机、端口转发、压缩、详细日志和密钥路径。
- 新增配置可以直接取消，取消后不会留下空白连接。
- 支持跳板机、目标主机、端口转发、密码、密钥和 SSH keepalive。
- 一键建立本地 Jupyter 隧道，并在应用内打开 Jupyter Lab。
- 一键建立本地 RStudio Server 隧道，并在应用内打开 RStudio 网页。
- 提供内置终端，也支持打开系统原生终端。
- 切换工作区时会保留已连接的终端和 SFTP 文件浏览状态，不会因为离开页面就丢掉侧栏里的路径和列表。
- 提供单个纯 SFTP 工作区；顶部每个标签都由左右 A/B 两栏共同组成，左侧默认 `127.0.0.1`，两栏都可从 Hosts 页面选择本地、终端工作区或自定义 SFTP 来源。
- 浏览本地和远程目录，支持 A/B 两栏间拖拽上传、下载和远程传输；自定义 SFTP Host 在 Hosts 区用按钮新增、编辑和删除，不靠右键菜单。
- 终端工作区的文件浏览器作为可展开侧栏显示，支持将 SFTP 路径复制到终端、同步到终端当前文件夹、自动跟随终端文件夹；目录跳转会先即时切换路径并在后台刷新，文件列表支持点击表头排序，也支持拖拽传输。
- 从 GitHub Releases 检查更新，并可直接下载、安装、重启到新版。

## 版本与发布

发布包由 GitHub Actions 自动构建，不需要用户自己 build。

维护者发布新版本时，推送一个 `v<版本>` tag：

```bash
git tag v<版本>
git push origin v<版本>
```

`Build Release Packages` workflow 会自动构建并上传：

```text
417ssh-<版本>-mac-app.zip
417ssh-<版本>-win-portable.zip
SHA256SUMS.txt
```

如果 Releases 页面还没有看到最新版本，通常说明 GitHub Actions 仍在构建，或发布 workflow 失败。可以在 [Actions](https://github.com/Vonfre/417ssh/actions) 页面查看 `Build Release Packages` 的运行状态。

## 项目结构

```text
macos/      原生 Swift/macOS 版本
windows/    Windows 版本，Python + PySide6/Qt + Paramiko
```

开发者本地运行和构建说明见：

- [macos/README.md](macos/README.md)
- [windows/README.md](windows/README.md)

## 注意事项

- macOS 版本以 app zip 分发；解压后得到的 `.app` 就是可运行应用，后续可在设置里直接更新。
- 当前 macOS 包尚未做 Apple Developer ID 公证，首次双击可能触发 Gatekeeper 提示；按上面的右键打开步骤即可继续。
- Windows 版本以 portable zip 分发；解压后运行 `417ssh.exe`，后续可在设置里直接更新。
- SSH 密码会随连接配置保存在应用配置里；如果不填写密码，应用会使用密钥或本机 SSH agent。
- 连接配置保存在本机用户目录，不会写入 GitHub 仓库或发布包。
- 旧版本或外部终端里已经启动的隧道不会被自动接管；如果端口被占用，可以在应用里关闭占用后重连。
