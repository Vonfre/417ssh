417ssh Windows 0.6.1

1. 解压整个 417ssh 文件夹。
2. 双击 417ssh.exe 运行。
3. 不要把 417ssh.exe 单独移出文件夹。

配置文件保存在：
%APPDATA%\417ssh\profiles.json

0.6.1 Windows 版本改为原生 WPF/.NET 实现，不再使用 Python/PySide6/QtWebEngine 打包。
如果程序启动失败或 WebView2 初始化失败，日志位于：
%LOCALAPPDATA%\417ssh\logs\windows-native.log
