# 417ssh

`417ssh` 是一个 SSH/Jupyter/SFTP 桌面工具，现在按平台拆成两套工程：

```text
macos/      原 Swift/macOS 版本，包含已有 417ssh.app 构建产物
windows/    Windows 版本，Python + PySide6/Qt + Paramiko
```

## 下载

- [下载最新版 macOS DMG](https://github.com/Vonfre/417ssh/releases/latest/download/417ssh-0.2.3-mac.dmg)
- [下载最新版 Windows MSI](https://github.com/Vonfre/417ssh/releases/latest/download/417ssh-0.2.3-win.msi)
- [打开 GitHub Releases 下载页](https://github.com/Vonfre/417ssh/releases)

## 推荐发布方式

在 GitHub Actions 里运行 `Build Release Installers` workflow，输入 tag，例如：

```text
v0.2.3
```

workflow 会自动：

- 在 macOS runner 构建 `417ssh-0.2.3-mac.dmg`
- 在 Windows runner 构建 `417ssh-0.2.3-win.msi`
- 创建或更新 GitHub Release
- 上传 `.dmg` 和 `.msi` 供用户直接下载

安装包不要提交进源码目录，也不要放在 `assets/` 或资源文件夹里；GitHub Release assets 才是给用户下载安装包的位置。

也可以直接 push tag 触发：

```bash
git tag v0.2.3
git push origin v0.2.3
```

如果 GitHub Actions 临时失败，也可以本地生成安装包后手动上传：

1. 打开 `https://github.com/Vonfre/417ssh/releases`
2. 点 `Draft a new release`
3. 选择或创建 tag，例如 `v0.2.0`
4. 上传 `417ssh-0.2.3-mac.dmg` 和 `417ssh-0.2.3-win.msi`
5. 发布 release

## macOS

进入 `macos/`：

```bash
./scripts/build_app.sh
```

生成：

```text
macos/build/417ssh.app
```

打包 DMG：

```bash
./scripts/build_dmg.sh
```

生成：

```text
macos/build/417ssh-0.2.3-mac.dmg
```

详细说明见 `macos/README.md`。

## Windows

进入 `windows/` 后双击：

```bat
run_windows.bat
```

需要打包 exe 时，在 PowerShell 里运行：

```powershell
.\build_windows.ps1
```

生成：

```text
windows/dist/417ssh.exe
```

打包 MSI：

```powershell
.\build_msi.ps1
```

生成：

```text
windows/dist/417ssh-0.2.3-win.msi
```

自动更新会读取 GitHub Releases。发布新版本时，把 macOS 的 `.dmg` 和 Windows 的 `.msi` 上传到 release assets。

详细说明见 `windows/README.md`。
