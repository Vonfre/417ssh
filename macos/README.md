# 417ssh

一个原生 macOS 应用，用来保存多组 SSH 配置，并把 Jupyter 隧道、SSH 终端和 SFTP 文件传输分成清晰的工作区。

默认示例配置对应：

```bash
ssh -CNgv -L 8003:node12:8003 -J zhanghuan@www.chenlianfu.com:52922 zhanghuan@node12
```

连接成功后，Jupyter 页会打开：

```text
http://127.0.0.1:8003/lab/tree/work
```

## 下载

- [下载最新版 macOS DMG](https://github.com/Vonfre/417ssh/releases/latest/download/417ssh-0.2.3-mac.dmg)
- [打开 GitHub Releases 下载页](https://github.com/Vonfre/417ssh/releases)

## 构建

推荐使用仓库根目录的 GitHub Actions workflow `Build Release Installers` 生成并上传 DMG。

本地构建：

```bash
./scripts/build_app.sh
```

生成的应用在：

```text
build/417ssh.app
```

打包 DMG：

```bash
./scripts/build_dmg.sh
```

生成：

```text
build/417ssh-0.2.3-mac.dmg
```

构建脚本会把 `logo.jpg` 复制进应用，并生成 macOS 需要的 `AppIcon.icns`。

## 使用

1. 打开 `417ssh`。
2. 左侧分为 `Jupyter 工作区` 和 `终端工作区`。
3. Jupyter 工作区用于建立本地端口转发，并在应用内打开 Jupyter Lab。
4. 终端工作区可以打开内置简易终端，也可以点击 `原生终端` 用 macOS Terminal.app 进入完整终端。
5. 终端工作区右侧会显示远程文件列表，可以刷新目录、拖拽上传、下载文件，并在传输时显示进度。
6. 点击连接旁边的铅笔按钮，可以修改主机、跳板机、密码和工作区类型。

## 说明

- 新增配置使用空白 SSH 模板，不会自动填入 node12 连接。
- Jupyter 和终端使用独立进程，互不影响；断开终端不会关闭 Jupyter 隧道。
- 隧道由 macOS 自带的 `/usr/bin/ssh` 建立。
- 如果填写密码，应用会用 `/usr/bin/expect` 自动响应 SSH、终端和 SFTP 的密码提示。
- 内置终端适合简单命令；需要 vim、top、复杂补全或完全一致的终端行为时，使用 `原生终端`。
- SSH 密码随连接配置保存在应用配置里，不使用 macOS 钥匙串。
- 应用退出时会自动关闭本次由应用创建的 Jupyter 隧道、SSH 终端和 SFTP 操作。
- 已经在终端或旧版本应用里启动的隧道不会被自动接管；端口占用时可以使用应用里的关闭占用重连按钮。
- 如果密码为空，应用会使用密钥或 `ssh-agent`。
- 设置里可以检查 GitHub Releases 更新；检测到新版本后会下载并打开 `.dmg`。
