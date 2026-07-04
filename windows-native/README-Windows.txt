417ssh Windows portable

1. 解压整个 417ssh 文件夹。
2. 双击 417ssh.exe 运行。
3. 不要把 417ssh.exe 单独移出文件夹。

配置文件保存在：
%APPDATA%\417ssh\profiles.json

0.6.4 Windows 版本修复了 SSH 快捷填写、Windows 密钥路径、~/.ssh/config 和默认私钥解析问题，方便从 macOS 迁移配置到 Windows。
0.6.3 Windows 版本修复了 -g / 允许局域网访问导致 SSH.NET 把 0.0.0.0 当作监听地址时报错的问题；Jupyter/RStudio 会优先保证本机 127.0.0.1 可连接。
更新器会把 zip 下载到当前 portable 目录下的 .417ssh-updates，下载完成后自动退出、替换当前 417ssh 文件夹内容、重启并清理更新包。
Windows 版本使用原生 WPF/.NET 实现，不再使用 Python/PySide6/QtWebEngine 打包。
如果程序启动失败或 WebView2 初始化失败，日志位于：
%LOCALAPPDATA%\417ssh\logs\windows-native.log
