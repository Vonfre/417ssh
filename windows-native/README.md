# 417ssh Windows Native

这是 417ssh 0.6.0 开始使用的 Windows 原生实现。

- UI: WPF / .NET 8
- Web 工作区: Microsoft Edge WebView2
- 终端: xterm.js + SSH.NET ShellStream PTY
- SFTP: SSH.NET SftpClient
- 配置文件: `%APPDATA%\417ssh\profiles.json`

这个工程替代旧的 Python + PySide6 Windows 发布包，目标是减少启动卡顿、减小分发体积，并让 Windows 功能和 macOS 版本保持同一套产品逻辑。

## 本地构建

```powershell
cd windows-native
$env:VERSION = "0.6.2"
.\build_portable.ps1
```

生成的 portable zip 位于 `windows-native\dist`。
