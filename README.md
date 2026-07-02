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

详细说明见 `windows/README.md`。
