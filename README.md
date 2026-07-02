# 417ssh

`417ssh` 是一个 SSH / Jupyter / SFTP 桌面工具，按平台拆成两套工程：

```text
macos/      原生 Swift/macOS 版本
windows/    Windows 版本，Python + PySide6/Qt + Paramiko
```

## 下载使用

打开 [GitHub Releases](https://github.com/Vonfre/417ssh/releases)，下载对应平台的发布包：

```text
macOS:   417ssh-<版本>-mac-app.zip
Windows: 417ssh-<版本>-win-portable.zip
```

macOS 使用方式：

1. 解压 `417ssh-<版本>-mac-app.zip`。
2. 得到 `417ssh.app`，可以直接运行，也可以拖到 `Applications`。
3. 如果系统提示无法打开，在 Finder 里右键 `417ssh.app`，选择 `打开`。

Windows 使用方式：

1. 解压 `417ssh-<版本>-win-portable.zip`。
2. 进入解压出的 `417ssh` 文件夹。
3. 双击 `417ssh.exe` 运行。

Windows portable 版本不需要用户安装 Python。配置文件保存在：

```text
%APPDATA%\417ssh\profiles.json
```

## 发布方式

在 GitHub Actions 里运行 `Build Release Packages` workflow，输入 tag。tag 需要以 `v` 开头，例如：

```text
v<版本>
```

workflow 会自动：

- 在 macOS runner 构建 `417ssh-<版本>-mac-app.zip`
- 在 Windows runner 构建 `417ssh-<版本>-win-portable.zip`
- 创建或更新 GitHub Release
- 上传两个 `.zip` 供用户下载

也可以直接 push tag 触发：

```bash
git tag v<版本>
git push origin v<版本>
```

发布包不要提交进源码目录，也不要放在 `assets/` 资源文件夹里；GitHub Release assets 才是给用户下载的位置。

## 本地构建

macOS：

```bash
cd macos
./scripts/build_app.sh
./scripts/build_zip.sh
```

生成：

```text
macos/build/417ssh.app
macos/build/417ssh-<版本>-mac-app.zip
```

Windows：

```powershell
cd windows
.\build_windows.ps1
.\build_portable.ps1
```

生成：

```text
windows\dist\417ssh.exe
windows\dist\417ssh-<版本>-win-portable.zip
```

自动更新会读取 GitHub Releases。发布新版本时，把 macOS 的 `.app.zip` 和 Windows 的 portable `.zip` 上传到 release assets。

更细的平台说明见 `macos/README.md` 和 `windows/README.md`。
