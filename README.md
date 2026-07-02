# 417ssh

`417ssh` 是一个 SSH/Jupyter/SFTP 桌面工具，现在按平台拆成两套工程：

```text
macos/      原 Swift/macOS 版本，包含已有 417ssh.app 构建产物
windows/    Windows 版本，Python + PySide6/Qt + Paramiko
```

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
macos/build/417ssh-0.2.0-mac.dmg
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
windows/dist/417ssh-0.2.0-win.msi
```

自动更新会读取 GitHub Releases。发布新版本时，把 macOS 的 `.dmg` 和 Windows 的 `.msi` 上传到 release assets。

详细说明见 `windows/README.md`。
