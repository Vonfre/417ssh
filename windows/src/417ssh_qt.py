from __future__ import annotations

import importlib.util
import json
import os
import posixpath
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
import zipfile
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QByteArray, QMimeData, QObject, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDragEnterEvent, QDropEvent, QFont, QIcon, QPixmap, QTextCursor
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QSplitter,
    QTabWidget,
    QTextEdit,
    QToolButton,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

try:
    from PySide6.QtWebEngineWidgets import QWebEngineView
except Exception:  # pragma: no cover - optional runtime fallback
    QWebEngineView = None


APP_NAME = "417ssh"


def bundled_root() -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parents[1]


APP_DIR = bundled_root()
ASSETS_DIR = APP_DIR / "assets"
CORE_PATH = APP_DIR / "417ssh_windows.py" if getattr(sys, "frozen", False) else Path(__file__).with_name("417ssh_windows.py")


def app_version() -> str:
    version_file = APP_DIR / "VERSION"
    if version_file.exists():
        text = version_file.read_text(encoding="utf-8").strip()
        if text:
            return text
    return "0.3.8"


CURRENT_VERSION = app_version()
GITHUB_REPO = "Vonfre/417ssh"
LATEST_RELEASE_API = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
RELEASES_URL = f"https://github.com/{GITHUB_REPO}/releases"


def load_core_module():
    spec = importlib.util.spec_from_file_location("ssh_core", CORE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载核心模块：{CORE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


core = load_core_module()
SSHProfile = core.SSHProfile
ProfileStore = core.ProfileStore
TunnelServer = core.TunnelServer
TerminalSession = core.TerminalSession
RemoteFileEntry = core.RemoteFileEntry
connect_ssh = core.connect_ssh
bytes_label = core.bytes_label
SETTINGS_FILE = core.CONFIG_DIR / "settings.json"
REMOTE_FILE_MIME = "application/x-417ssh-remote-file"


def load_app_settings() -> dict:
    defaults = {"auto_check_updates": True}
    if not SETTINGS_FILE.exists():
        return defaults
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            defaults.update({key: value for key, value in data.items() if key in defaults})
    except Exception:
        pass
    return defaults


def save_app_settings(settings: dict) -> None:
    core.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")


def endpoint_parts(value: str, default_port: int | None = None) -> tuple[str, str, int | None]:
    endpoint = value.strip()
    user = ""
    if "@" in endpoint:
        user, endpoint = endpoint.rsplit("@", 1)
    host = endpoint
    port = default_port
    if ":" in endpoint:
        possible_host, possible_port = endpoint.rsplit(":", 1)
        if possible_port:
            try:
                host = possible_host
                port = int(possible_port)
            except ValueError as exc:
                raise ValueError(f"端口不是有效数字：{possible_port}") from exc
    return user, host, port


def parse_forward_spec(value: str) -> tuple[int, str, int]:
    parts = value.split(":")
    if len(parts) == 3:
        local_port, remote_host, remote_port = parts
    elif len(parts) == 4:
        _bind_host, local_port, remote_host, remote_port = parts
    else:
        raise ValueError(f"无法识别 -L 转发：{value}")
    try:
        return int(local_port), remote_host, int(remote_port)
    except ValueError as exc:
        raise ValueError(f"无法识别 -L 转发：{value}") from exc


def apply_short_flags(token: str, values: dict) -> None:
    for flag in token[1:]:
        if flag == "C":
            values["compressionEnabled"] = True
        elif flag == "v":
            values["verboseLogging"] = True
        elif flag == "g":
            values["allowRemoteLocalPortAccess"] = True


def option_consumes_next_token(token: str) -> bool:
    return token in {"-B", "-b", "-c", "-D", "-E", "-e", "-I", "-m", "-O", "-Q", "-R", "-S", "-W", "-w"}


def truthy_ssh_option(value: str) -> bool:
    return value.strip().lower() in {"yes", "true", "1", "on"}


def normalized_forward_option(value: str) -> str:
    parts = value.split()
    if len(parts) == 2:
        return f"{parts[0]}:{parts[1]}"
    return value


def apply_ssh_option(value: str, values: dict) -> None:
    text = value.strip()
    if not text:
        return
    if "=" in text:
        key, option_value = text.split("=", 1)
    else:
        parts = text.split(None, 1)
        if len(parts) != 2:
            return
        key, option_value = parts

    key = key.strip().lower()
    option_value = option_value.strip()
    if key == "proxyjump":
        jump_user, jump_host, jump_port = endpoint_parts(option_value, 22)
        values["jumpUser"] = jump_user
        values["jumpHost"] = jump_host
        values["jumpPort"] = jump_port or 22
    elif key == "user":
        values["targetUser"] = option_value
    elif key == "port":
        values["targetPort"] = int(option_value)
    elif key == "identityfile":
        values["identityFile"] = option_value
    elif key == "localforward":
        values["localPort"], values["remoteHost"], values["remotePort"] = parse_forward_spec(normalized_forward_option(option_value))
    elif key == "compression":
        values["compressionEnabled"] = truthy_ssh_option(option_value)


def profile_from_ssh_command(profile: SSHProfile, command: str, name: str = "", password: str = "") -> SSHProfile:
    try:
        tokens = shlex.split(command.strip())
    except ValueError as exc:
        raise ValueError(f"命令引号不完整：{exc}") from exc
    if not tokens:
        raise ValueError("SSH 命令为空。")

    values = profile.to_dict()
    values["compressionEnabled"] = False
    values["verboseLogging"] = False
    values["allowRemoteLocalPortAccess"] = False
    index = 1 if tokens[0].endswith("ssh") or tokens[0].endswith("ssh.exe") else 0
    target = ""

    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            index += 1
            target = tokens[index] if index < len(tokens) else ""
            break
        if not token.startswith("-") or token == "-":
            target = token
            break

        if token == "-L":
            index += 1
            if index >= len(tokens):
                raise ValueError("缺少 -L 转发参数。")
            values["localPort"], values["remoteHost"], values["remotePort"] = parse_forward_spec(tokens[index])
        elif token.startswith("-L") and len(token) > 2:
            values["localPort"], values["remoteHost"], values["remotePort"] = parse_forward_spec(token[2:])
        elif token == "-J":
            index += 1
            if index >= len(tokens):
                raise ValueError("缺少 -J 跳板机参数。")
            jump_user, jump_host, jump_port = endpoint_parts(tokens[index], 22)
            values["jumpUser"] = jump_user
            values["jumpHost"] = jump_host
            values["jumpPort"] = jump_port or 22
        elif token.startswith("-J") and len(token) > 2:
            jump_user, jump_host, jump_port = endpoint_parts(token[2:], 22)
            values["jumpUser"] = jump_user
            values["jumpHost"] = jump_host
            values["jumpPort"] = jump_port or 22
        elif token == "-p":
            index += 1
            if index >= len(tokens):
                raise ValueError("缺少 -p 端口参数。")
            values["targetPort"] = int(tokens[index])
        elif token.startswith("-p") and len(token) > 2:
            values["targetPort"] = int(token[2:])
        elif token == "-l":
            index += 1
            if index < len(tokens):
                values["targetUser"] = tokens[index]
        elif token.startswith("-l") and len(token) > 2:
            values["targetUser"] = token[2:]
        elif token == "-i":
            index += 1
            if index < len(tokens):
                values["identityFile"] = tokens[index]
        elif token.startswith("-i") and len(token) > 2:
            values["identityFile"] = token[2:]
        elif token == "-o":
            index += 1
            if index < len(tokens):
                apply_ssh_option(tokens[index], values)
        elif token.startswith("-o") and len(token) > 2:
            apply_ssh_option(token[2:], values)
        elif token == "-F" or option_consumes_next_token(token):
            index += 1
        elif token.startswith("-") and not token.startswith("--"):
            apply_short_flags(token, values)
        index += 1

    if not target:
        raise ValueError("没有识别到目标主机，例如 user@target-host。")
    target_user, target_host, target_port = endpoint_parts(target, values.get("targetPort") or 22)
    if not target_host:
        raise ValueError("没有识别到目标主机，例如 user@target-host。")
    values["targetUser"] = target_user or values.get("targetUser", "")
    values["targetHost"] = target_host
    values["targetPort"] = target_port or 22
    if name.strip():
        values["name"] = name.strip()
    if password:
        values["sshPassword"] = password
    return SSHProfile.from_dict(values)


def version_parts(version: str) -> list[int]:
    cleaned = version.strip().lstrip("vV")
    parts: list[int] = []
    current = ""
    for char in cleaned:
        if char.isdigit():
            current += char
        elif current:
            parts.append(int(current))
            current = ""
    if current:
        parts.append(int(current))
    return parts


def is_version_newer(candidate: str, current: str) -> bool:
    left = version_parts(candidate)
    right = version_parts(current)
    count = max(len(left), len(right), 3)
    for index in range(count):
        lhs = left[index] if index < len(left) else 0
        rhs = right[index] if index < len(right) else 0
        if lhs != rhs:
            return lhs > rhs
    return False


def release_version(release: dict) -> str:
    return str(release.get("tag_name") or "").strip().lstrip("vV")


def windows_release_asset(release: dict) -> dict | None:
    assets = release.get("assets") or []
    zip_assets = [
        asset for asset in assets
        if str(asset.get("name", "")).lower().endswith(".zip")
    ]
    for asset in zip_assets:
        name = str(asset.get("name", "")).lower()
        if ("win" in name or "windows" in name) and ("portable" in name or "417ssh" in name):
            return asset
    for asset in zip_assets:
        name = str(asset.get("name", "")).lower()
        if "win" in name or "windows" in name or "417ssh" in name:
            return asset

    return None


def fetch_latest_release() -> dict:
    request = urllib.request.Request(
        LATEST_RELEASE_API,
        headers={
            "User-Agent": f"417ssh/{CURRENT_VERSION}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(github_http_error_message(exc.code)) from exc


def github_http_error_message(status: int) -> str:
    if status == 404:
        return "GitHub 返回 HTTP 404。请确认仓库和 Releases 是 public，并且已经有 latest release。"
    return f"GitHub 返回 HTTP {status}"


def update_work_dir() -> Path:
    root = Path(tempfile.gettempdir()) / "417ssh-updates"
    root.mkdir(parents=True, exist_ok=True)
    return root


def download_release_asset(asset: dict) -> Path:
    name = str(asset.get("name") or "417ssh-update.zip")
    url = str(asset.get("browser_download_url") or "")
    if not url:
        raise RuntimeError("Release asset 缺少下载地址。")

    target_dir = update_work_dir()
    destination = target_dir / name

    request = urllib.request.Request(url, headers={"User-Agent": f"417ssh/{CURRENT_VERSION}"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            with destination.open("wb") as handle:
                while True:
                    chunk = response.read(1024 * 512)
                    if not chunk:
                        break
                    handle.write(chunk)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(github_http_error_message(exc.code)) from exc
    return destination


def prepare_windows_update(package_path: Path) -> Path:
    if sys.platform != "win32" or not getattr(sys, "frozen", False):
        raise RuntimeError("自动替换只能在打包后的 Windows portable 版中使用。")

    install_root = update_work_dir() / f"install-{os.getpid()}-{int(time.time())}"
    staging_dir = install_root / "staging"
    staging_dir.mkdir(parents=True, exist_ok=True)

    safe_extract_zip(package_path, staging_dir)
    new_app_dir = find_windows_app_dir(staging_dir)

    current_exe = Path(sys.executable).resolve()
    current_dir = current_exe.parent
    backup_dir = install_root / "backup"
    script_path = update_work_dir() / f"install-417ssh-update-{os.getpid()}-{int(time.time())}.bat"
    script_path.write_text(
        windows_update_script(
            pid=os.getpid(),
            new_app_dir=new_app_dir,
            current_dir=current_dir,
            backup_dir=backup_dir,
            cleanup_dir=install_root,
        ),
        encoding="utf-8",
    )
    return script_path


def safe_extract_zip(package_path: Path, destination: Path) -> None:
    destination_root = destination.resolve()
    with zipfile.ZipFile(package_path) as archive:
        for member in archive.infolist():
            member_path = (destination / member.filename).resolve()
            try:
                common_path = os.path.commonpath([str(destination_root), str(member_path)])
            except ValueError as exc:
                raise RuntimeError("更新包包含不安全路径。") from exc
            if common_path != str(destination_root):
                raise RuntimeError("更新包包含不安全路径。")
        archive.extractall(destination)


def find_windows_app_dir(staging_dir: Path) -> Path:
    candidates = [path for path in staging_dir.rglob("417ssh.exe") if path.is_file()]
    if not candidates:
        raise RuntimeError("更新包里没有找到 417ssh.exe。")

    for candidate in candidates:
        if candidate.parent.name.lower() == APP_NAME.lower():
            return candidate.parent
    return candidates[0].parent


def batch_value(path: Path | str) -> str:
    return str(path).replace("%", "%%")


def windows_update_script(
    pid: int,
    new_app_dir: Path,
    current_dir: Path,
    backup_dir: Path,
    cleanup_dir: Path,
) -> str:
    return f"""@echo off
setlocal
set "APP_PID={pid}"
set "SRC={batch_value(new_app_dir)}"
set "DST={batch_value(current_dir)}"
set "BACKUP={batch_value(backup_dir)}"
set "CLEANUP={batch_value(cleanup_dir)}"
set "EXE=417ssh.exe"
set /A WAIT_COUNT=0

timeout /T 1 /NOBREAK >NUL
taskkill /PID %APP_PID% /T >NUL 2>NUL

:wait_for_app
tasklist /FI "PID eq %APP_PID%" 2>NUL | find "%APP_PID%" >NUL
if not errorlevel 1 (
  if %WAIT_COUNT% GEQ 15 (
    taskkill /PID %APP_PID% /T /F >NUL 2>NUL
  )
  if %WAIT_COUNT% GEQ 30 (
    exit /B 1
  )
  set /A WAIT_COUNT+=1
  timeout /T 1 /NOBREAK >NUL
  goto wait_for_app
)

if exist "%BACKUP%" rmdir /S /Q "%BACKUP%" >NUL 2>NUL
mkdir "%BACKUP%" >NUL 2>NUL
robocopy "%DST%" "%BACKUP%" /E /NFL /NDL /NJH /NJS /NP >NUL
robocopy "%SRC%" "%DST%" /E /NFL /NDL /NJH /NJS /NP >NUL
set "COPY_CODE=%ERRORLEVEL%"

if %COPY_CODE% LEQ 7 (
  start "" "%DST%\\%EXE%"
  rmdir /S /Q "%BACKUP%" >NUL 2>NUL
  rmdir /S /Q "%CLEANUP%" >NUL 2>NUL
  del "%~f0" >NUL 2>NUL
  exit /B 0
)

robocopy "%BACKUP%" "%DST%" /E /NFL /NDL /NJH /NJS /NP >NUL
start "" "%DST%\\%EXE%"
exit /B %COPY_CODE%
"""


def launch_windows_update_script(script_path: Path) -> None:
    creationflags = 0
    if sys.platform == "win32":
        creationflags |= subprocess.CREATE_NEW_PROCESS_GROUP
        if hasattr(subprocess, "DETACHED_PROCESS"):
            creationflags |= subprocess.DETACHED_PROCESS

    subprocess.Popen(
        ["cmd", "/c", str(script_path)],
        close_fds=True,
        creationflags=creationflags,
    )


class Bridge(QObject):
    tunnel_log = Signal(str)
    tunnel_status = Signal(str, object)
    terminal_output = Signal(str)
    terminal_status = Signal(str, object)
    sftp_done = Signal(list, str)
    sftp_error = Signal(str)
    sftp_status = Signal(str)
    update_done = Signal(dict, object)
    update_error = Signal(str)
    update_downloaded = Signal(str)
    update_status = Signal(str)


def clear_layout(layout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        child_layout = item.layout()
        if widget is not None:
            widget.deleteLater()
        if child_layout is not None:
            clear_layout(child_layout)


def make_logo(size: int) -> QLabel:
    label = QLabel()
    label.setFixedSize(size, size)
    logo = ASSETS_DIR / "logo.jpg"
    if logo.exists():
        pixmap = QPixmap(str(logo))
        if not pixmap.isNull():
            label.setPixmap(pixmap.scaled(size, size, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation))
            label.setStyleSheet("border-radius: 8px;")
            return label
    label.setText("417")
    label.setAlignment(Qt.AlignCenter)
    label.setStyleSheet(
        "background: #eef6ff; color: #2658b8; border: 1px solid rgba(38,88,184,0.16); border-radius: 8px;"
        "font-weight: 700;"
    )
    return label


def status_color(status: str) -> str:
    if status in {"connected", "文件完成", "终端已连接", "已连接"}:
        return "#158a4b"
    if status in {"connecting", "文件处理中", "文件同步中", "正在上传", "正在下载", "终端连接中"}:
        return "#b96200"
    if status in {"failed", "文件失败", "终端失败", "连接失败"}:
        return "#c23535"
    return "#64706b"


class StatusPill(QLabel):
    def __init__(self, text: str, color: str) -> None:
        super().__init__(text)
        self.setText(text)
        self.set_color(color)

    def set_color(self, color: str) -> None:
        self.setStyleSheet(
            f"color: {color}; background: {QColor(color).lighter(190).name()};"
            "border-radius: 11px; padding: 4px 9px; font-size: 12px; font-weight: 600;"
        )


class ProfileRow(QFrame):
    clicked = Signal(str)
    edit_clicked = Signal(str)

    def __init__(self, profile: SSHProfile, selected: bool, active: bool) -> None:
        super().__init__()
        self.profile = profile
        self.setObjectName("ProfileRow")
        self.setCursor(Qt.PointingHandCursor)
        self.setStyleSheet(self.row_style(selected, active))

        layout = QHBoxLayout(self)
        layout.setContentsMargins(9, 8, 8, 8)
        layout.setSpacing(8)

        icon_text = (
            "R"
            if profile.workspaceKind == "rstudio"
            else ("J" if profile.workspaceKind == "jupyter" else ("S" if profile.workspaceKind == "sftp" else ">_"))
        )
        icon = QLabel(icon_text)
        icon.setFixedSize(30, 30)
        icon.setAlignment(Qt.AlignCenter)
        icon.setStyleSheet(
            "background: #e7f3ee; color: #26734d; border-radius: 7px; font-weight: 700;"
            if active
            else "background: #eef1f2; color: #61716b; border-radius: 7px; font-weight: 700;"
        )
        layout.addWidget(icon)

        text_box = QVBoxLayout()
        text_box.setSpacing(2)
        title = QLabel(profile.name)
        title.setStyleSheet("font-weight: 650;")
        title.setWordWrap(False)
        subtitle_text = (
            f"{profile.localPort} -> {profile.remoteHost}:{profile.remotePort}"
            if profile.is_web_workspace
            else (profile.target_address or "未填写目标主机")
        )
        subtitle = QLabel(subtitle_text)
        subtitle.setStyleSheet("color: #6b7280; font-size: 12px;")
        text_box.addWidget(title)
        text_box.addWidget(subtitle)
        layout.addLayout(text_box, 1)

        edit = QToolButton()
        edit.setText("配置")
        edit.setToolTip("修改配置")
        edit.setAutoRaise(True)
        edit.clicked.connect(lambda: self.edit_clicked.emit(profile.id))
        layout.addWidget(edit)

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.LeftButton:
            self.clicked.emit(self.profile.id)
        super().mousePressEvent(event)

    @staticmethod
    def row_style(selected: bool, active: bool) -> str:
        if selected:
            background = "#eaf2ff"
            border = "#a9c3f5"
        elif active:
            background = "#e8f6ef"
            border = "#acdcbc"
        else:
            background = "rgba(255,255,255,0.72)"
            border = "rgba(80,95,90,0.14)"
        return f"#ProfileRow {{ background: {background}; border: 1px solid {border}; border-radius: 8px; }}"


class ProfileEditor(QDialog):
    saved = Signal(object)

    def __init__(self, profile: SSHProfile, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.profile = SSHProfile.from_dict(profile.to_dict())
        self.fields: dict[str, QWidget] = {}
        self.web_only_widgets: list[QWidget] = []
        self.import_status: QLabel | None = None
        self.setWindowTitle("修改配置")
        self.resize(640, 720)
        self.setMinimumSize(560, 620)
        self.build()

    def build(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(10)

        header = QFrame()
        header.setStyleSheet("background: #f5f8fa; border: 1px solid #dce4e1; border-radius: 8px;")
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(12, 10, 12, 10)
        header_layout.addWidget(make_logo(40))
        title_box = QVBoxLayout()
        title = QLabel("修改配置")
        title.setStyleSheet("font-size: 17px; font-weight: 700;")
        subtitle = QLabel(self.profile.name)
        subtitle.setStyleSheet("color: #6b7280;")
        title_box.addWidget(title)
        title_box.addWidget(subtitle)
        header_layout.addLayout(title_box, 1)
        cancel = QPushButton("取消")
        cancel.clicked.connect(self.reject)
        header_layout.addWidget(cancel)
        done = QPushButton("完成")
        done.setProperty("primary", True)
        done.clicked.connect(self.save)
        header_layout.addWidget(done)
        root.addWidget(header)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        form_holder = QWidget()
        self.form = QVBoxLayout(form_holder)
        self.form.setContentsMargins(4, 4, 4, 12)
        self.form.setSpacing(12)
        scroll.setWidget(form_holder)
        root.addWidget(scroll, 1)

        self.add_section("基本配置")
        workspace_combo = self.add_combo("workspaceKind", "工作区", [("Jupyter", "jupyter"), ("RStudio", "rstudio"), ("终端", "terminal"), ("SFTP", "sftp")])
        self.add_line("name", "名称")
        self.add_line("sshPassword", "SSH 密码", password=True)
        self.add_ssh_import_box()
        self.web_only_widgets.append(self.add_line("jupyterPath", "页面路径"))

        self.web_only_widgets.append(self.add_section("网页本地转发"))
        self.web_only_widgets.append(self.add_spin("localPort", "本地端口", 1, 65535))
        self.web_only_widgets.append(self.add_line("remoteHost", "远程主机"))
        self.web_only_widgets.append(self.add_spin("remotePort", "远程端口", 1, 65535))
        self.web_only_widgets.append(self.add_check("allowRemoteLocalPortAccess", "启用 -g"))

        self.add_section("跳板机")
        self.add_line("jumpUser", "用户名")
        self.add_line("jumpHost", "主机")
        self.add_spin("jumpPort", "端口", 1, 65535)

        self.add_section("目标主机")
        self.add_line("targetUser", "用户名")
        self.add_line("targetHost", "主机")
        self.add_spin("targetPort", "SSH 端口", 1, 65535)
        self.add_line("identityFile", "密钥文件")
        self.add_check("compressionEnabled", "启用压缩 (-C)")
        self.add_check("verboseLogging", "详细日志 (-v)")

        self.add_section("连接稳定性")
        self.add_check("keepAliveEnabled", "保持长连接")
        self.add_spin("keepAliveInterval", "保活间隔", 1, 3600)
        self.add_spin("keepAliveCountMax", "容错次数", 1, 1000)
        self.add_check("useSSHConfig", "使用本机 ~/.ssh/config")

        self.add_section("命令预览")
        self.preview = QTextEdit()
        self.preview.setReadOnly(True)
        self.preview.setFixedHeight(78)
        self.preview.setPlainText(self.profile.preview_command())
        self.preview.setStyleSheet("font-family: Consolas, monospace; color: #6b7280;")
        self.form.addWidget(self.preview)
        self.form.addStretch(1)
        workspace_combo.currentIndexChanged.connect(self.update_field_visibility)
        self.connect_form_updates()
        self.update_field_visibility()

    def add_section(self, title: str) -> QLabel:
        label = QLabel(title)
        label.setStyleSheet("font-size: 14px; font-weight: 700; margin-top: 6px;")
        self.form.addWidget(label)
        return label

    def row(self, label_text: str) -> tuple[QWidget, QHBoxLayout]:
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 0, 0, 0)
        label = QLabel(label_text)
        label.setFixedWidth(92)
        label.setStyleSheet("color: #6b7280;")
        layout.addWidget(label)
        self.form.addWidget(row)
        return row, layout

    def add_line(self, name: str, label: str, password: bool = False) -> QWidget:
        row, layout = self.row(label)
        field = QLineEdit(str(getattr(self.profile, name)))
        if password:
            field.setEchoMode(QLineEdit.Password)
        layout.addWidget(field, 1)
        self.fields[name] = field
        return row

    def add_spin(self, name: str, label: str, low: int, high: int) -> QWidget:
        row, layout = self.row(label)
        field = QSpinBox()
        field.setRange(low, high)
        field.setValue(int(getattr(self.profile, name)))
        field.setMaximumWidth(150)
        layout.addWidget(field)
        layout.addStretch(1)
        self.fields[name] = field
        return row

    def add_check(self, name: str, label: str) -> QCheckBox:
        checkbox = QCheckBox(label)
        checkbox.setChecked(bool(getattr(self.profile, name)))
        self.form.addWidget(checkbox)
        self.fields[name] = checkbox
        return checkbox

    def add_combo(self, name: str, label: str, choices: list[tuple[str, str]]) -> QComboBox:
        _, layout = self.row(label)
        combo = QComboBox()
        for text, value in choices:
            combo.addItem(text, value)
        index = combo.findData(getattr(self.profile, name))
        combo.setCurrentIndex(max(0, index))
        combo.setMaximumWidth(220)
        layout.addWidget(combo)
        layout.addStretch(1)
        self.fields[name] = combo
        return combo

    def add_ssh_import_box(self) -> None:
        self.add_section("快捷填写")
        self.command_import = QTextEdit()
        self.command_import.setPlaceholderText("ssh -CNgv -L 8000:remote-host:8888 -J user@jump.example.com:22 user@target-host")
        self.command_import.setFixedHeight(92)
        self.form.addWidget(self.command_import)

        import_row = QHBoxLayout()
        import_button = QPushButton("识别并填入")
        import_button.clicked.connect(self.import_ssh_command)
        import_row.addWidget(import_button)
        self.import_status = QLabel("")
        self.import_status.setWordWrap(True)
        self.import_status.setStyleSheet("color: #6b7280;")
        import_row.addWidget(self.import_status, 1)
        self.form.addLayout(import_row)

    def current_form_profile(self) -> SSHProfile:
        values = self.profile.to_dict()
        for name, widget in self.fields.items():
            if isinstance(widget, QLineEdit):
                values[name] = widget.text()
            elif isinstance(widget, QSpinBox):
                values[name] = widget.value()
            elif isinstance(widget, QCheckBox):
                values[name] = widget.isChecked()
            elif isinstance(widget, QComboBox):
                values[name] = widget.currentData()
        return SSHProfile.from_dict(values)

    def apply_profile_to_fields(self, profile: SSHProfile) -> None:
        self.profile = profile
        for name, widget in self.fields.items():
            value = getattr(profile, name)
            if isinstance(widget, QLineEdit):
                widget.setText(str(value))
            elif isinstance(widget, QSpinBox):
                widget.setValue(int(value))
            elif isinstance(widget, QCheckBox):
                widget.setChecked(bool(value))
            elif isinstance(widget, QComboBox):
                index = widget.findData(value)
                widget.setCurrentIndex(max(0, index))
        if hasattr(self, "preview"):
            self.preview.setPlainText(profile.preview_command())
        self.update_field_visibility()

    def connect_form_updates(self) -> None:
        for widget in self.fields.values():
            if isinstance(widget, QLineEdit):
                widget.textChanged.connect(self.update_preview_from_fields)
            elif isinstance(widget, QSpinBox):
                widget.valueChanged.connect(self.update_preview_from_fields)
            elif isinstance(widget, QCheckBox):
                widget.toggled.connect(self.update_preview_from_fields)
            elif isinstance(widget, QComboBox):
                widget.currentIndexChanged.connect(self.update_preview_from_fields)

    def update_field_visibility(self, *_args) -> None:
        workspace = self.fields.get("workspaceKind")
        kind = workspace.currentData() if isinstance(workspace, QComboBox) else self.profile.workspaceKind
        is_web = kind in {"jupyter", "rstudio"}
        for widget in self.web_only_widgets:
            widget.setVisible(is_web)
        self.update_preview_from_fields()

    def update_preview_from_fields(self, *_args) -> None:
        if not hasattr(self, "preview"):
            return
        try:
            self.preview.setPlainText(self.current_form_profile().preview_command())
        except Exception:
            pass

    def import_ssh_command(self) -> None:
        try:
            imported = profile_from_ssh_command(
                self.current_form_profile(),
                self.command_import.toPlainText(),
            )
            self.apply_profile_to_fields(imported)
            if self.import_status is not None:
                self.import_status.setText("已识别并填入当前配置。")
                self.import_status.setStyleSheet("color: #6b7280;")
        except Exception as exc:
            if self.import_status is not None:
                self.import_status.setText(f"无法识别：{exc}")
                self.import_status.setStyleSheet("color: #c23535;")

    def save(self) -> None:
        self.saved.emit(self.current_form_profile())
        self.accept()


class AppSettingsDialog(QDialog):
    settings_changed = Signal(dict)
    check_requested = Signal()
    install_requested = Signal()

    def __init__(
        self,
        settings: dict,
        update_status: str,
        latest_release: dict | None,
        update_asset: dict | None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.settings = dict(settings)
        self.latest_release = latest_release
        self.update_asset = update_asset
        self.setWindowTitle("417ssh 设置")
        self.resize(580, 480)
        self.setMinimumWidth(520)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(14)

        header = QHBoxLayout()
        header.addWidget(make_logo(42))
        title_box = QVBoxLayout()
        title = QLabel("417ssh 设置")
        title.setStyleSheet("font-size: 18px; font-weight: 750;")
        subtitle = QLabel(f"版本 {CURRENT_VERSION}")
        subtitle.setStyleSheet("color: #6b7280;")
        title_box.addWidget(title)
        title_box.addWidget(subtitle)
        header.addLayout(title_box, 1)
        layout.addLayout(header)

        self.auto_check = QCheckBox("启动时自动检查 GitHub 更新")
        self.auto_check.setChecked(bool(self.settings.get("auto_check_updates", True)))
        self.auto_check.toggled.connect(self.on_auto_check_toggled)
        layout.addWidget(self.auto_check)

        info_box = QFrame()
        info_box.setStyleSheet("background: #f6f8f8; border: 1px solid #dfe5e3; border-radius: 8px;")
        info_layout = QVBoxLayout(info_box)
        info_layout.setContentsMargins(12, 10, 12, 10)
        info_layout.setSpacing(6)
        self.current_version_label = QLabel(f"当前版本：{CURRENT_VERSION}")
        self.latest_version_label = QLabel("最新版本：尚未检查")
        self.update_asset_label = QLabel("更新包：尚未检查")
        for label in (self.current_version_label, self.latest_version_label, self.update_asset_label):
            label.setWordWrap(True)
            label.setStyleSheet("color: #38423f; font-size: 12px;")
            info_layout.addWidget(label)
        layout.addWidget(info_box)

        self.status_label = QLabel()
        self.status_label.setWordWrap(True)
        layout.addWidget(self.status_label)

        self.release_notes = QTextEdit()
        self.release_notes.setReadOnly(True)
        self.release_notes.setFixedHeight(115)
        layout.addWidget(self.release_notes)

        button_row = QHBoxLayout()
        self.check_button = QPushButton("检查更新")
        self.check_button.clicked.connect(self.check_requested.emit)
        button_row.addWidget(self.check_button)

        self.install_button = QPushButton("下载并安装更新")
        self.install_button.clicked.connect(self.install_requested.emit)
        button_row.addWidget(self.install_button)

        releases = QPushButton("打开 GitHub Releases")
        releases.clicked.connect(lambda: webbrowser.open(RELEASES_URL))
        button_row.addWidget(releases)
        button_row.addStretch(1)
        layout.addLayout(button_row)

        tip = QLabel("Windows 版会下载 GitHub Release 中的 portable .zip，自动解压并替换当前 portable 文件夹，然后重启应用。")
        tip.setWordWrap(True)
        tip.setStyleSheet("color: #6b7280; font-size: 12px;")
        layout.addWidget(tip)
        layout.addStretch(1)

        self.set_update_state(update_status, latest_release, update_asset)

    def on_auto_check_toggled(self, checked: bool) -> None:
        self.settings["auto_check_updates"] = checked
        self.settings_changed.emit(dict(self.settings))

    def set_update_state(self, update_status: str, latest_release: dict | None, update_asset: dict | None) -> None:
        self.latest_release = latest_release
        self.update_asset = update_asset
        self.status_label.setText(update_status)
        self.latest_version_label.setText(
            f"最新版本：{release_version(latest_release)}" if latest_release else "最新版本：尚未检查"
        )
        if update_asset:
            self.update_asset_label.setText(f"更新包：{update_asset.get('name', '未知')}")
        elif latest_release:
            self.update_asset_label.setText("更新包：未找到 Windows portable .zip 更新包")
        else:
            self.update_asset_label.setText("更新包：尚未检查")
        self.install_button.setText("下载并安装新版" if update_asset is not None and "发现新版本" in update_status else "下载并安装更新")
        self.install_button.setEnabled(update_asset is not None and "发现新版本" in update_status)
        self.check_button.setEnabled("正在" not in update_status)

        if latest_release:
            title = latest_release.get("name") or latest_release.get("tag_name") or "417ssh 更新"
            body = latest_release.get("body") or "这个版本没有填写 release notes。"
            asset_name = update_asset.get("name") if update_asset else "未找到 Windows portable .zip 更新包"
            self.release_notes.setPlainText(f"{title}\n\n更新包：{asset_name}\n\n{body}")
        else:
            self.release_notes.setPlainText("还没有检查更新。")


class RemoteFileTree(QTreeWidget):
    dropped_paths = Signal(list)
    remote_dropped = Signal(dict)
    context_requested = Signal(object, object)

    def __init__(self) -> None:
        super().__init__()
        self.drag_profile_id: str | None = None
        self.local_drag_enabled = False
        self.setAcceptDrops(True)
        self.setDragEnabled(True)
        self.setDragDropMode(QAbstractItemView.DragDrop)
        self.setDefaultDropAction(Qt.CopyAction)
        self.setSortingEnabled(True)
        self.sortByColumn(0, Qt.AscendingOrder)
        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self.show_context_menu)

    def mimeData(self, items: list) -> QMimeData:
        mime = QMimeData()
        if not items:
            return mime
        item = items[0]
        if bool(item.data(0, Qt.UserRole + 6)):
            return mime
        if self.local_drag_enabled:
            path = str(item.data(0, Qt.UserRole) or "")
            if path:
                mime.setUrls([QUrl.fromLocalFile(path)])
                mime.setText(path)
            return mime
        payload = {
            "profile_id": self.drag_profile_id,
            "name": item.text(0),
            "path": item.data(0, Qt.UserRole),
            "is_dir": bool(item.data(0, Qt.UserRole + 1)),
        }
        mime.setData(REMOTE_FILE_MIME, QByteArray(json.dumps(payload).encode("utf-8")))
        mime.setText(item.text(0))
        return mime

    def show_context_menu(self, point) -> None:
        item = self.itemAt(point)
        if item is not None:
            self.setCurrentItem(item)
        self.context_requested.emit(item, self.viewport().mapToGlobal(point))

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls() or event.mimeData().hasFormat(REMOTE_FILE_MIME):
            event.acceptProposedAction()
        else:
            super().dragEnterEvent(event)

    def dragMoveEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls() or event.mimeData().hasFormat(REMOTE_FILE_MIME):
            event.acceptProposedAction()
        else:
            super().dragMoveEvent(event)

    def dropEvent(self, event: QDropEvent) -> None:
        if event.mimeData().hasFormat(REMOTE_FILE_MIME):
            try:
                payload = json.loads(bytes(event.mimeData().data(REMOTE_FILE_MIME)).decode("utf-8"))
                if isinstance(payload, dict):
                    self.remote_dropped.emit(payload)
                    event.acceptProposedAction()
                    return
            except Exception:
                pass

        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        if paths:
            self.dropped_paths.emit(paths)
            event.acceptProposedAction()
            return
        super().dropEvent(event)


class RemoteFileTreeItem(QTreeWidgetItem):
    def __lt__(self, other) -> bool:
        tree = self.treeWidget()
        column = tree.sortColumn() if tree is not None else 0

        self_is_parent = bool(self.data(0, Qt.UserRole + 6))
        other_is_parent = bool(other.data(0, Qt.UserRole + 6))
        if self_is_parent != other_is_parent:
            return self_is_parent

        self_is_dir = bool(self.data(0, Qt.UserRole + 1))
        other_is_dir = bool(other.data(0, Qt.UserRole + 1))
        if self_is_dir != other_is_dir:
            return self_is_dir

        role_by_column = {
            0: Qt.UserRole + 2,
            1: Qt.UserRole + 3,
            2: Qt.UserRole + 4,
            3: Qt.UserRole + 5,
        }
        role = role_by_column.get(column, Qt.UserRole + 2)
        left = self.data(0, role)
        right = other.data(0, role)
        if left == right:
            return str(self.data(0, Qt.UserRole + 2)) < str(other.data(0, Qt.UserRole + 2))
        return left < right


class SFTPPaneState:
    def __init__(self, profile_id: str | None = None) -> None:
        self.token = str(time.time_ns())
        self.profile_id = profile_id
        self.current_path = "."
        self.entries: list[RemoteFileEntry] = []
        self.status = "文件空闲"
        self.pending_path: str | None = None
        self.filter_text = ""


class SFTPTabState(SFTPPaneState):
    def __init__(self, source_kind: str | None = "local", profile_id: str | None = None, title: str = "127.0.0.1") -> None:
        super().__init__(profile_id)
        self.source_kind = source_kind
        self.title = title
        if source_kind == "local":
            self.current_path = str(Path.home())
        elif source_kind is None:
            self.current_path = str(Path.home())
            self.status = "选择主机"

    @classmethod
    def local(cls) -> "SFTPTabState":
        return cls("local", None, "127.0.0.1")

    @classmethod
    def empty(cls) -> "SFTPTabState":
        return cls(None, None, "新标签")

    @property
    def is_local(self) -> bool:
        return self.source_kind == "local"


class LocalSFTPPaneWidget(QFrame):
    done = Signal(list, str)
    error = Signal(str)
    status_changed = Signal(str)

    def __init__(self, controller: "MainWindow", state: SFTPTabState) -> None:
        super().__init__()
        self.controller = controller
        self.state = state
        self.setStyleSheet("QFrame { background: white; border: 1px solid #d1d8d6; border-radius: 8px; }")
        self.build_ui()
        self.done.connect(self.handle_done)
        self.error.connect(self.handle_error)
        self.status_changed.connect(self.handle_status)
        QTimer.singleShot(0, self.refresh_if_needed)

    def build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(6)

        top = QHBoxLayout()
        top.setSpacing(6)
        title = QLabel("127.0.0.1")
        title.setStyleSheet("font-size: 13px; font-weight: 750;")
        top.addWidget(title)
        self.status_pill = StatusPill(self.state.status, status_color(self.state.status))
        top.addWidget(self.status_pill)
        top.addStretch(1)
        refresh = QToolButton()
        refresh.setText("刷新")
        refresh.setToolTip("刷新当前目录")
        refresh.clicked.connect(lambda: self.refresh())
        top.addWidget(refresh)
        layout.addLayout(top)

        path_row = QHBoxLayout()
        path_row.setSpacing(6)
        up = QPushButton("上级")
        up.clicked.connect(self.go_parent)
        path_row.addWidget(up)
        self.path_input = QLineEdit(self.state.current_path)
        self.path_input.returnPressed.connect(lambda: self.refresh(self.path_input.text()))
        path_row.addWidget(self.path_input, 1)
        open_path = QPushButton("打开")
        open_path.clicked.connect(lambda: self.refresh(self.path_input.text()))
        path_row.addWidget(open_path)
        layout.addLayout(path_row)

        action_row = QHBoxLayout()
        action_row.setSpacing(6)
        self.filter_input = QLineEdit(self.state.filter_text)
        self.filter_input.setPlaceholderText("筛选")
        self.filter_input.textChanged.connect(self.handle_filter_changed)
        action_row.addWidget(self.filter_input, 1)

        menu_button = QToolButton()
        menu_button.setText("操作")
        menu_button.setPopupMode(QToolButton.InstantPopup)
        menu = QMenu(menu_button)
        menu.addAction("刷新", lambda: self.refresh())
        menu.addAction("上级文件夹", self.go_parent)
        menu.addSeparator()
        menu.addAction("复制到当前目录", self.choose_copy_here)
        menu.addAction("复制选中项到...", self.copy_selected_to_folder)
        menu.addAction("新建文件夹", self.create_folder)
        menu.addSeparator()
        menu.addAction("复制到目标目录", self.copy_selected_to_path)
        menu.addAction("重命名", self.rename_selected)
        menu.addAction("修改权限", self.edit_selected_permissions)
        menu.addAction("删除", self.delete_selected)
        menu_button.setMenu(menu)
        action_row.addWidget(menu_button)
        layout.addLayout(action_row)

        self.tree = RemoteFileTree()
        self.tree.local_drag_enabled = True
        self.tree.setIconSize(QSize(16, 16))
        self.tree.setIndentation(14)
        self.tree.setStyleSheet("QTreeWidget::item { padding: 1px 0; }")
        self.tree.setHeaderLabels(["名称", "修改时间", "大小", "类型"])
        self.tree.setColumnWidth(0, 260)
        self.tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected())
        self.tree.dropped_paths.connect(self.copy_paths_here)
        self.tree.remote_dropped.connect(self.handle_remote_drop)
        self.tree.context_requested.connect(self.show_context_menu)
        layout.addWidget(self.tree, 1)
        self.populate()

    def refresh_if_needed(self) -> None:
        if not self.state.entries:
            self.refresh(self.state.current_path)

    def refresh(self, path: str | None = None) -> None:
        target = Path((path or self.state.current_path or str(Path.home())).strip()).expanduser()
        if not target.exists():
            QMessageBox.warning(self, APP_NAME, f"路径不存在：{target}")
            return
        if target.is_file():
            self.controller.open_local_path(target)
            return
        try:
            entries, actual = self.list_local_directory(target)
            self.handle_done(entries, actual)
        except Exception as exc:
            self.handle_error(str(exc))

    def list_local_directory(self, path: Path) -> tuple[list[RemoteFileEntry], str]:
        actual = path.resolve(strict=False)
        entries: list[RemoteFileEntry] = []
        if actual.parent != actual:
            entries.append(
                RemoteFileEntry(
                    name="..",
                    path=str(actual.parent),
                    is_dir=True,
                    is_link=False,
                    permissions="上级目录",
                    size="",
                    modified="",
                )
            )
        children = []
        for child in actual.iterdir():
            try:
                stat_result = child.lstat()
            except OSError:
                continue
            is_dir = child.is_dir()
            is_link = child.is_symlink()
            children.append(
                RemoteFileEntry(
                    name=child.name,
                    path=str(child),
                    is_dir=is_dir,
                    is_link=is_link,
                    permissions=stat.filemode(stat_result.st_mode),
                    size="--" if is_dir else bytes_label(stat_result.st_size),
                    modified=time.strftime("%Y-%m-%d %H:%M", time.localtime(stat_result.st_mtime)),
                )
            )
        children.sort(key=lambda item: (not item.is_dir, item.name.lower()))
        return entries + children, str(actual)

    def handle_done(self, entries: list, actual: str) -> None:
        self.state.entries = list(entries)
        self.state.current_path = actual
        self.state.status = "本地文件"
        self.state.pending_path = None
        self.update_widgets()

    def handle_error(self, message: str) -> None:
        self.state.status = "文件失败"
        self.state.pending_path = None
        self.update_widgets()
        QMessageBox.critical(self, APP_NAME, message)

    def handle_status(self, status: str) -> None:
        self.state.status = status
        self.update_widgets()

    def update_widgets(self) -> None:
        self.status_pill.setText(self.state.status)
        self.status_pill.set_color(status_color(self.state.status))
        if self.path_input.text() != self.state.current_path:
            self.path_input.setText(self.state.current_path)
        self.populate()

    def handle_filter_changed(self, text: str) -> None:
        self.state.filter_text = text
        self.populate()

    def populate(self) -> None:
        needle = self.state.filter_text.strip().lower()
        self.tree.clear()
        for entry in self.state.entries:
            if needle and needle not in entry.name.lower():
                continue
            self.tree.addTopLevelItem(self.controller.make_remote_file_item(entry))

    def selected_entry(self) -> RemoteFileEntry | None:
        items = self.tree.selectedItems()
        if not items:
            return None
        path = items[0].data(0, Qt.UserRole)
        return next((entry for entry in self.state.entries if entry.path == path), None)

    def mutable_entry(self) -> RemoteFileEntry | None:
        entry = self.selected_entry()
        if entry is None:
            QMessageBox.information(self, APP_NAME, "请先选择一个本地文件或文件夹。")
            return None
        if entry.name == "..":
            QMessageBox.information(self, APP_NAME, "上级目录不能执行这个操作。")
            return None
        return entry

    def show_context_menu(self, item: object, global_point: object) -> None:
        entry = self.controller.remote_entry_for_item_in_entries(item, self.state.entries)
        menu = QMenu(self)
        if entry is None:
            menu.addAction("刷新", lambda: self.refresh())
            menu.addAction("新建文件夹", self.create_folder)
            menu.addSeparator()
            menu.addAction("复制到当前目录", self.choose_copy_here)
            menu.exec(global_point)
            return

        is_parent = entry.name == ".."
        menu.addAction("打开", lambda: self.open_entry(entry))
        copy_to_folder = menu.addAction("复制选中项到...", lambda: self.copy_to_folder(entry))
        menu.addSeparator()
        copy_action = menu.addAction("复制到目标目录", lambda: self.copy_to_path(entry))
        rename_action = menu.addAction("重命名", lambda: self.rename_entry(entry))
        delete_action = menu.addAction("删除", lambda: self.delete_entry(entry))
        menu.addSeparator()
        menu.addAction("刷新", lambda: self.refresh())
        menu.addAction("新建文件夹", self.create_folder)
        chmod_action = menu.addAction("修改权限", lambda: self.edit_permissions(entry))
        for action in (copy_to_folder, copy_action, rename_action, delete_action, chmod_action):
            action.setEnabled(not is_parent)
        menu.exec(global_point)

    def open_selected(self) -> None:
        entry = self.selected_entry()
        if entry is not None:
            self.open_entry(entry)

    def open_entry(self, entry: RemoteFileEntry) -> None:
        if entry.is_dir:
            self.refresh(entry.path)
            return
        self.controller.open_local_path(Path(entry.path))

    def go_parent(self) -> None:
        path = Path(self.state.current_path)
        if path.parent == path:
            return
        self.refresh(str(path.parent))

    def choose_copy_here(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "选择要复制的文件")
        folder = QFileDialog.getExistingDirectory(self, "也可以选择文件夹；直接取消则只复制文件")
        selected = list(paths)
        if folder:
            selected.append(folder)
        if selected:
            self.copy_paths_here(selected)

    def copy_paths_here(self, paths: list[str]) -> None:
        if paths:
            self.copy_paths(paths, self.state.current_path)

    def copy_selected_to_folder(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.copy_to_folder(entry)

    def copy_to_folder(self, entry: RemoteFileEntry) -> None:
        target_dir = QFileDialog.getExistingDirectory(self, "选择复制位置")
        if target_dir:
            self.copy_paths([entry.path], target_dir)

    def copy_selected_to_path(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.copy_to_path(entry)

    def copy_to_path(self, entry: RemoteFileEntry) -> None:
        target_dir, ok = QInputDialog.getText(self, "复制到目标目录", "输入本地目标目录：", text=self.state.current_path)
        target_dir = target_dir.strip()
        if ok and target_dir:
            self.copy_paths([entry.path], target_dir)

    def copy_paths(self, paths: list[str], target_dir: str) -> None:
        target = Path(target_dir).expanduser()

        def worker() -> None:
            if not target.exists() or not target.is_dir():
                raise RuntimeError(f"目标目录不可用：{target}")
            for raw_path in paths:
                source = Path(raw_path).expanduser()
                destination = target / source.name
                if destination.exists():
                    raise RuntimeError(f"目标已存在：{destination}")
                if source.is_dir():
                    shutil.copytree(source, destination, symlinks=True)
                else:
                    shutil.copy2(source, destination)

        self.run_operation("文件处理中", worker)

    def rename_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.rename_entry(entry)

    def rename_entry(self, entry: RemoteFileEntry) -> None:
        new_name, ok = QInputDialog.getText(self, "重命名", "输入新的名称：", text=entry.name)
        new_name = new_name.strip()
        if not ok or not new_name or new_name == entry.name:
            return
        if "/" in new_name or "\\" in new_name or new_name in {".", ".."}:
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含路径分隔符。")
            return

        def worker() -> None:
            Path(entry.path).rename(Path(entry.path).with_name(new_name))

        self.run_operation("文件处理中", worker)

    def delete_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.delete_entry(entry)

    def delete_entry(self, entry: RemoteFileEntry) -> None:
        prompt = f"确定删除文件夹“{entry.name}”及其中所有内容吗？" if entry.is_dir else f"确定删除文件“{entry.name}”吗？"
        if QMessageBox.question(self, "删除", prompt) != QMessageBox.Yes:
            return

        def worker() -> None:
            path = Path(entry.path)
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()

        self.run_operation("文件处理中", worker)

    def create_folder(self) -> None:
        folder_name, ok = QInputDialog.getText(self, "新建文件夹", "输入文件夹名称：", text="新建文件夹")
        folder_name = folder_name.strip()
        if not ok or not folder_name:
            return
        if "/" in folder_name or "\\" in folder_name or folder_name in {".", ".."}:
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含路径分隔符。")
            return

        def worker() -> None:
            target = Path(self.state.current_path) / folder_name
            if target.exists():
                raise RuntimeError(f"目标已存在：{target}")
            target.mkdir()

        self.run_operation("文件处理中", worker)

    def edit_selected_permissions(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.edit_permissions(entry)

    def edit_permissions(self, entry: RemoteFileEntry) -> None:
        mode, ok = QInputDialog.getText(self, "修改权限", "输入 chmod 权限，例如 755、664：", text="755" if entry.is_dir else "644")
        mode = mode.strip()
        if not ok or not mode:
            return
        try:
            value = int(mode, 8)
        except ValueError:
            QMessageBox.warning(self, APP_NAME, "请输入八进制权限，例如 755。")
            return
        self.run_operation("文件处理中", lambda: os.chmod(entry.path, value))

    def handle_remote_drop(self, payload: dict) -> None:
        source_profile = self.controller.profile_by_id(str(payload.get("profile_id") or ""))
        if source_profile is None:
            QMessageBox.warning(self, APP_NAME, "没有找到拖拽来源配置。")
            return
        entry = RemoteFileEntry(
            name=str(payload.get("name") or "remote-file"),
            path=str(payload.get("path") or ""),
            is_dir=bool(payload.get("is_dir")),
            is_link=False,
            permissions="",
            size="",
            modified="",
        )
        self.run_operation("正在下载", lambda: self.controller.download_path(source_profile, entry, Path(self.state.current_path)))

    def run_operation(self, status: str, worker: Callable) -> None:
        self.status_changed.emit(status)

        def work() -> None:
            try:
                worker()
                entries, actual = self.list_local_directory(Path(self.state.current_path))
                self.done.emit(entries, actual)
            except Exception as exc:
                self.error.emit(str(exc))

        threading.Thread(target=work, name="LocalSFTPOperation", daemon=True).start()


class SFTPPaneWidget(QFrame):
    done = Signal(list, str)
    error = Signal(str)
    status_changed = Signal(str)

    def __init__(
        self,
        controller: "MainWindow",
        state: SFTPPaneState,
        title: str,
        show_profile_combo: bool = True,
    ) -> None:
        super().__init__()
        self.controller = controller
        self.state = state
        self.title = title
        self.show_profile_combo = show_profile_combo
        self.setStyleSheet("QFrame { background: white; border: 1px solid #d1d8d6; border-radius: 8px; }")
        self.build_ui()
        self.done.connect(self.handle_done)
        self.error.connect(self.handle_error)
        self.status_changed.connect(self.handle_status)
        QTimer.singleShot(0, self.refresh_if_needed)

    def build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(6)

        top = QHBoxLayout()
        top.setSpacing(6)
        pane_title = QLabel(self.title)
        pane_title.setStyleSheet("color: #6b7280; font-size: 12px; font-weight: 700;")
        top.addWidget(pane_title)

        source_profiles = self.controller.sftp_source_profiles()
        if self.state.profile_id is None and source_profiles:
            self.state.profile_id = source_profiles[0].id
        if self.show_profile_combo:
            self.profile_combo = QComboBox()
            for profile in source_profiles:
                self.profile_combo.addItem(profile.name, profile.id)
            if self.state.profile_id is not None:
                index = self.profile_combo.findData(self.state.profile_id)
                if index < 0 and source_profiles:
                    self.state.profile_id = source_profiles[0].id
                    index = 0
                self.profile_combo.setCurrentIndex(max(0, index))
            self.profile_combo.currentIndexChanged.connect(lambda _index: self.change_profile())
            top.addWidget(self.profile_combo, 1)
        else:
            profile = self.current_profile()
            host_label = QLabel(profile.target_address if profile is not None and profile.target_address else "未填写目标主机")
            host_label.setStyleSheet("color: #6b7280; font-size: 12px;")
            top.addWidget(host_label, 1)

        self.status_pill = StatusPill(self.state.status, status_color(self.state.status))
        top.addWidget(self.status_pill)

        refresh = QToolButton()
        refresh.setText("刷新")
        refresh.setToolTip("刷新当前目录")
        refresh.clicked.connect(lambda: self.refresh())
        top.addWidget(refresh)

        layout.addLayout(top)

        path_row = QHBoxLayout()
        path_row.setSpacing(6)
        up = QPushButton("上级")
        up.clicked.connect(self.go_parent)
        path_row.addWidget(up)
        self.path_input = QLineEdit(self.state.current_path)
        self.path_input.returnPressed.connect(lambda: self.refresh(self.path_input.text()))
        path_row.addWidget(self.path_input, 1)
        open_path = QPushButton("打开")
        open_path.clicked.connect(lambda: self.refresh(self.path_input.text()))
        path_row.addWidget(open_path)
        layout.addLayout(path_row)

        action_row = QHBoxLayout()
        action_row.setSpacing(6)
        self.filter_input = QLineEdit(self.state.filter_text)
        self.filter_input.setPlaceholderText("筛选")
        self.filter_input.textChanged.connect(self.handle_filter_changed)
        action_row.addWidget(self.filter_input, 1)

        menu_button = QToolButton()
        menu_button.setText("操作")
        menu_button.setPopupMode(QToolButton.InstantPopup)
        menu = QMenu(menu_button)
        menu.addAction("刷新", lambda: self.refresh())
        menu.addAction("上级文件夹", self.go_parent)
        menu.addSeparator()
        menu.addAction("上传文件", self.choose_upload_files)
        menu.addAction("上传文件夹", self.choose_upload_folder)
        menu.addAction("下载选中项", self.download_selected)
        menu.addAction("新建文件夹", self.create_folder)
        menu.addSeparator()
        menu.addAction("复制到目标目录", self.copy_selected)
        menu.addAction("重命名", self.rename_selected)
        menu.addAction("修改权限", self.edit_selected_permissions)
        menu.addAction("删除", self.delete_selected)
        menu_button.setMenu(menu)
        action_row.addWidget(menu_button)
        layout.addLayout(action_row)

        self.tree = RemoteFileTree()
        self.tree.setIconSize(QSize(16, 16))
        self.tree.setIndentation(14)
        self.tree.setStyleSheet("QTreeWidget::item { padding: 1px 0; }")
        self.tree.drag_profile_id = self.state.profile_id
        self.tree.setHeaderLabels(["名称", "修改时间", "大小", "类型"])
        self.tree.setColumnWidth(0, 240)
        self.tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected())
        self.tree.dropped_paths.connect(self.upload_paths)
        self.tree.remote_dropped.connect(self.handle_remote_drop)
        self.tree.context_requested.connect(self.show_context_menu)
        layout.addWidget(self.tree, 1)
        self.populate()

    def current_profile(self) -> SSHProfile | None:
        profile_id = self.state.profile_id
        return next((profile for profile in self.controller.sftp_source_profiles() if profile.id == profile_id), None)

    def change_profile(self) -> None:
        self.state.profile_id = self.profile_combo.currentData()
        self.state.current_path = "."
        self.state.entries = []
        self.state.status = "文件空闲"
        self.state.pending_path = None
        self.tree.drag_profile_id = self.state.profile_id
        self.update_widgets()
        self.refresh()

    def refresh_if_needed(self) -> None:
        profile = self.current_profile()
        if profile is not None and profile.targetHost.strip() and not self.state.entries:
            self.refresh(self.state.current_path)

    def refresh(self, path: str | None = None) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        if not profile.targetHost.strip():
            self.state.status = "未填写目标主机"
            self.state.entries = []
            self.update_widgets()
            return
        remote_path = (path or self.state.current_path or ".").strip() or "."
        self.begin_navigation(profile, remote_path)

        def work() -> None:
            try:
                entries, actual = self.controller.list_remote_directory(profile, remote_path)
                self.done.emit(entries, actual)
            except Exception as exc:
                self.error.emit(str(exc))

        threading.Thread(target=work, name="SFTPPaneList", daemon=True).start()

    def begin_navigation(self, profile: SSHProfile, remote_path: str) -> None:
        self.state.status = "文件同步中"
        self.state.pending_path = remote_path
        cached = self.controller.directory_cache.get(self.controller.directory_cache_key(profile, remote_path))
        if cached is not None:
            entries, actual = cached
            self.state.entries = list(entries)
            self.state.current_path = actual
        else:
            self.state.current_path = remote_path
            parent = self.controller.parent_remote_entry(remote_path)
            self.state.entries = [parent] if parent is not None else []
        self.update_widgets()

    def handle_done(self, entries: list, actual: str) -> None:
        profile = self.current_profile()
        self.state.entries = list(entries)
        self.state.current_path = actual
        self.state.status = "文件完成"
        if profile is not None:
            self.controller.directory_cache[self.controller.directory_cache_key(profile, actual)] = (list(entries), actual)
            if self.state.pending_path:
                self.controller.directory_cache[self.controller.directory_cache_key(profile, self.state.pending_path)] = (list(entries), actual)
        self.state.pending_path = None
        self.update_widgets()

    def handle_error(self, message: str) -> None:
        self.state.status = "文件失败"
        self.state.pending_path = None
        self.update_widgets()
        QMessageBox.critical(self, APP_NAME, message)

    def handle_status(self, status: str) -> None:
        self.state.status = status
        self.update_widgets()

    def update_widgets(self) -> None:
        self.status_pill.setText(self.state.status)
        self.status_pill.set_color(status_color(self.state.status))
        if self.path_input.text() != self.state.current_path:
            self.path_input.setText(self.state.current_path)
        self.tree.drag_profile_id = self.state.profile_id
        self.populate()

    def handle_filter_changed(self, text: str) -> None:
        self.state.filter_text = text
        self.populate()

    def populate(self) -> None:
        needle = self.state.filter_text.strip().lower()
        self.tree.clear()
        for entry in self.state.entries:
            if needle and needle not in entry.name.lower():
                continue
            item = self.controller.make_remote_file_item(entry)
            self.tree.addTopLevelItem(item)

    def selected_entry(self) -> RemoteFileEntry | None:
        items = self.tree.selectedItems()
        if not items:
            return None
        path = items[0].data(0, Qt.UserRole)
        return next((entry for entry in self.state.entries if entry.path == path), None)

    def mutable_entry(self) -> RemoteFileEntry | None:
        entry = self.selected_entry()
        if entry is None:
            QMessageBox.information(self, APP_NAME, "请先选择一个远程文件或文件夹。")
            return None
        if entry.name == "..":
            QMessageBox.information(self, APP_NAME, "上级目录不能执行这个操作。")
            return None
        return entry

    def show_context_menu(self, item: object, global_point: object) -> None:
        entry = self.controller.remote_entry_for_item_in_entries(item, self.state.entries)
        menu = QMenu(self)
        if entry is None:
            menu.addAction("刷新", lambda: self.refresh())
            menu.addAction("新建文件夹", self.create_folder)
            menu.addSeparator()
            menu.addAction("上传文件", self.choose_upload_files)
            menu.addAction("上传文件夹", self.choose_upload_folder)
            menu.exec(global_point)
            return

        is_parent = entry.name == ".."
        menu.addAction("打开", lambda: self.open_entry(entry))
        download_action = menu.addAction("下载到本地", lambda: self.download_entry(entry))
        menu.addSeparator()
        copy_action = menu.addAction("复制到目标目录", lambda: self.copy_entry(entry))
        rename_action = menu.addAction("重命名", lambda: self.rename_entry(entry))
        delete_action = menu.addAction("删除", lambda: self.delete_entry(entry))
        menu.addSeparator()
        menu.addAction("刷新", lambda: self.refresh())
        menu.addAction("新建文件夹", self.create_folder)
        chmod_action = menu.addAction("修改权限", lambda: self.edit_permissions(entry))
        for action in (download_action, copy_action, rename_action, delete_action, chmod_action):
            action.setEnabled(not is_parent)
        menu.exec(global_point)

    def open_selected(self) -> None:
        entry = self.selected_entry()
        if entry is not None:
            self.open_entry(entry)

    def open_entry(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        if entry.is_dir:
            self.refresh(entry.path)
            return
        target_dir = Path(tempfile.mkdtemp(prefix="417ssh-open-"))
        local_path = target_dir / (entry.name or "remote-file")
        self.run_operation("正在打开", lambda: (self.controller.download_file_to_path(profile, entry.path, local_path), self.controller.open_local_path(local_path)))

    def go_parent(self) -> None:
        path = self.state.current_path.strip()
        if not path or path in {".", "/"}:
            return
        self.refresh(posixpath.dirname(path.rstrip("/")) or "/")

    def choose_upload_files(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "选择要上传的文件")
        if paths:
            self.upload_paths(paths)

    def choose_upload_folder(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "选择要上传的文件夹")
        if path:
            self.upload_paths([path])

    def upload_paths(self, paths: list[str]) -> None:
        profile = self.current_profile()
        if profile is None or not paths:
            return
        remote_dir = self.state.current_path or "."

        def worker() -> None:
            for local in paths:
                self.controller.upload_path(profile, Path(local), remote_dir)

        self.run_operation("正在上传", worker, refresh_path=remote_dir)

    def handle_remote_drop(self, payload: dict) -> None:
        profile = self.current_profile()
        source_profile = self.controller.profile_by_id(str(payload.get("profile_id") or ""))
        if profile is None or source_profile is None:
            QMessageBox.warning(self, APP_NAME, "没有找到拖拽来源或目标配置。")
            return
        remote_dir = self.state.current_path or "."
        self.run_operation(
            "正在上传",
            lambda: self.controller.transfer_remote_payload(source_profile, payload, profile, remote_dir),
            refresh_path=remote_dir,
        )

    def download_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.download_entry(entry)

    def download_entry(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        target_dir = QFileDialog.getExistingDirectory(self, "选择下载位置")
        if not target_dir:
            return
        self.run_operation("正在下载", lambda: self.controller.download_path(profile, entry, Path(target_dir)))

    def copy_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.copy_entry(entry)

    def copy_entry(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        target_dir, ok = QInputDialog.getText(self, "复制到目标目录", "输入远程目标目录：", text=self.state.current_path)
        target_dir = target_dir.strip()
        if not ok or not target_dir:
            return
        self.run_operation(
            "文件处理中",
            lambda: self.controller.copy_remote_path(profile, entry.path, target_dir),
            refresh_path=self.state.current_path,
        )

    def rename_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.rename_entry(entry)

    def rename_entry(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        new_name, ok = QInputDialog.getText(self, "重命名", "输入新的名称：", text=entry.name)
        new_name = new_name.strip()
        if not ok or not new_name or new_name == entry.name:
            return
        if not self.controller.valid_remote_basename(new_name):
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含 /。")
            return
        target_path = self.controller.join_remote_path(posixpath.dirname(entry.path.rstrip("/")) or "/", new_name)

        def worker() -> None:
            def action(sftp, _connection) -> None:
                try:
                    sftp.stat(target_path)
                    raise RuntimeError(f"目标已存在：{target_path}")
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                sftp.rename(entry.path, target_path)

            self.controller.run_with_sftp(profile, action)

        self.run_operation("文件处理中", worker, refresh_path=self.state.current_path)

    def delete_selected(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.delete_entry(entry)

    def delete_entry(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        prompt = f"确定删除文件夹“{entry.name}”及其中所有内容吗？" if entry.is_dir else f"确定删除文件“{entry.name}”吗？"
        if QMessageBox.question(self, "删除", prompt) != QMessageBox.Yes:
            return
        self.run_operation("文件处理中", lambda: self.controller.remove_remote_path(profile, entry.path), refresh_path=self.state.current_path)

    def create_folder(self) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        folder_name, ok = QInputDialog.getText(self, "新建文件夹", "输入文件夹名称：", text="新建文件夹")
        folder_name = folder_name.strip()
        if not ok or not folder_name:
            return
        if not self.controller.valid_remote_basename(folder_name):
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含 /。")
            return
        target_path = self.controller.join_remote_path(self.state.current_path or ".", folder_name)

        def worker() -> None:
            def action(sftp, _connection) -> None:
                try:
                    sftp.stat(target_path)
                    raise RuntimeError(f"目标已存在：{target_path}")
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                sftp.mkdir(target_path)

            self.controller.run_with_sftp(profile, action)

        self.run_operation("文件处理中", worker, refresh_path=self.state.current_path)

    def edit_selected_permissions(self) -> None:
        entry = self.mutable_entry()
        if entry is not None:
            self.edit_permissions(entry)

    def edit_permissions(self, entry: RemoteFileEntry) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        mode, ok = QInputDialog.getText(
            self,
            "修改权限",
            "输入 chmod 权限，例如 755、664 或 u+x：",
            text=self.controller.default_permission_mode(entry),
        )
        mode = mode.strip()
        if not ok or not mode:
            return
        script = f"chmod {shlex.quote(mode)} -- {shlex.quote(entry.path)}"
        self.run_operation("文件处理中", lambda: self.controller.run_remote_shell(profile, script), refresh_path=self.state.current_path)

    def run_operation(self, status: str, worker: Callable, refresh_path: str | None = None) -> None:
        profile = self.current_profile()
        if profile is None:
            return
        self.status_changed.emit(status)

        def work() -> None:
            try:
                worker()
                if refresh_path:
                    self.controller.invalidate_directory_cache(profile, refresh_path)
                    entries, actual = self.controller.list_remote_directory(profile, refresh_path)
                    self.done.emit(entries, actual)
                else:
                    self.status_changed.emit("文件完成")
            except Exception as exc:
                self.error.emit(str(exc))

        threading.Thread(target=work, name="SFTPPaneOperation", daemon=True).start()


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.store = ProfileStore()
        self.bridge = Bridge()
        self.tunnel: TunnelServer | None = None
        self.tunnel_profile_id: str | None = None
        self.tunnel_status = "disconnected"
        self.tunnel_message: str | None = None
        self.tunnel_log_text = ""
        self.terminal: TerminalSession | None = None
        self.terminal_profile_id: str | None = None
        self.terminal_status = "disconnected"
        self.terminal_text = ""
        self.sftp_status = "文件空闲"
        self.remote_entries: list[RemoteFileEntry] = []
        self.current_remote_path = "."
        self.current_webview = None
        self.app_settings = load_app_settings()
        self.update_status = "尚未检查更新"
        self.latest_release: dict | None = None
        self.update_asset: dict | None = None
        self.settings_dialog: AppSettingsDialog | None = None
        self.update_check_silent = False
        self.sftp_connections: dict[str, object] = {}
        self.sftp_locks: dict[str, threading.RLock] = {}
        self.sftp_connection_guard = threading.RLock()
        self.file_sidebar_visible = False
        self.directory_cache: dict[tuple[str, str], tuple[list[RemoteFileEntry], str]] = {}
        self.sftp_workspace_tabs_by_profile: dict[str, list[SFTPTabState]] = {}
        self.sftp_workspace_selected_tab_by_profile: dict[str, int] = {}

        self.setWindowTitle(APP_NAME)
        self.resize(1180, 760)
        self.setMinimumSize(980, 640)
        self.install_event_handlers()
        self.build_shell()
        self.refresh_sidebar()
        self.render_selected_profile()
        if self.app_settings.get("auto_check_updates", True):
            QTimer.singleShot(1200, lambda: self.check_updates(silent=True))

    def install_event_handlers(self) -> None:
        self.bridge.tunnel_log.connect(self.append_tunnel_log)
        self.bridge.tunnel_status.connect(self.handle_tunnel_status)
        self.bridge.terminal_output.connect(self.append_terminal_output)
        self.bridge.terminal_status.connect(self.handle_terminal_status)
        self.bridge.sftp_done.connect(self.handle_sftp_done)
        self.bridge.sftp_error.connect(self.handle_sftp_error)
        self.bridge.sftp_status.connect(self.handle_sftp_status)
        self.bridge.update_done.connect(self.handle_update_done)
        self.bridge.update_error.connect(self.handle_update_error)
        self.bridge.update_downloaded.connect(self.handle_update_downloaded)
        self.bridge.update_status.connect(self.handle_update_status)

    def build_shell(self) -> None:
        splitter = QSplitter(Qt.Horizontal)
        splitter.setChildrenCollapsible(False)
        self.setCentralWidget(splitter)

        self.sidebar = QFrame()
        self.sidebar.setObjectName("Sidebar")
        self.sidebar.setMinimumWidth(240)
        self.sidebar.setMaximumWidth(330)
        sidebar_layout = QVBoxLayout(self.sidebar)
        sidebar_layout.setContentsMargins(10, 12, 10, 10)
        sidebar_layout.setSpacing(10)

        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(4, 0, 4, 0)
        header_layout.addWidget(make_logo(38))
        title_box = QVBoxLayout()
        title_box.setSpacing(1)
        app_title = QLabel(APP_NAME)
        app_title.setStyleSheet("font-size: 16px; font-weight: 750;")
        subtitle = QLabel("连接 / 终端 / 文件")
        subtitle.setStyleSheet("color: #6b7280; font-size: 12px;")
        title_box.addWidget(app_title)
        title_box.addWidget(subtitle)
        header_layout.addLayout(title_box, 1)
        sidebar_layout.addWidget(header)

        self.profile_scroll = QScrollArea()
        self.profile_scroll.setWidgetResizable(True)
        self.profile_scroll.setFrameShape(QFrame.NoFrame)
        self.profile_holder = QWidget()
        self.profile_layout = QVBoxLayout(self.profile_holder)
        self.profile_layout.setContentsMargins(0, 0, 0, 0)
        self.profile_layout.setSpacing(13)
        self.profile_scroll.setWidget(self.profile_holder)
        sidebar_layout.addWidget(self.profile_scroll, 1)

        bottom = QHBoxLayout()
        bottom.setSpacing(6)
        add_button = QPushButton("增加")
        add_menu = QMenu(add_button)
        for text, kind in (
            ("Jupyter 工作区", "jupyter"),
            ("RStudio 工作区", "rstudio"),
            ("终端工作区", "terminal"),
            ("SFTP 工作区", "sftp"),
        ):
            action = add_menu.addAction(text)
            action.triggered.connect(lambda _checked=False, selected_kind=kind: self.add_profile(selected_kind))
        add_button.setMenu(add_menu)
        bottom.addWidget(add_button, 1)

        delete_button = QPushButton("删除")
        delete_button.clicked.connect(self.delete_profile)
        bottom.addWidget(delete_button, 1)

        settings_button = QPushButton("设置")
        settings_button.clicked.connect(self.open_settings)
        bottom.addWidget(settings_button, 1)
        sidebar_layout.addLayout(bottom)
        splitter.addWidget(self.sidebar)

        self.detail = QFrame()
        self.detail_layout = QVBoxLayout(self.detail)
        self.detail_layout.setContentsMargins(0, 0, 0, 0)
        self.detail_layout.setSpacing(0)
        splitter.addWidget(self.detail)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)

        self.setStyleSheet(
            """
            QMainWindow { background: #f6f8f9; }
            #Sidebar { background: #f2f6f5; border-right: 1px solid #dbe3e0; }
            QPushButton { padding: 6px 10px; border-radius: 6px; border: 1px solid #c5d0cc; background: #ffffff; }
            QPushButton:hover { background: #eef4f2; }
            QPushButton:disabled { color: #98a29e; background: #f4f6f6; }
            QPushButton[primary="true"] { background: #245fc7; color: white; border-color: #245fc7; font-weight: 650; }
            QPushButton[primary="true"]:hover { background: #1f55b5; }
            QToolButton { padding: 4px 7px; border-radius: 5px; }
            QToolButton:hover { background: rgba(0,0,0,0.06); }
            QLineEdit, QSpinBox, QComboBox { padding: 6px; border: 1px solid #c5d0cc; border-radius: 6px; background: white; }
            QLineEdit:focus, QSpinBox:focus, QComboBox:focus { border-color: #8dacdf; }
            QPlainTextEdit, QTextEdit, QTreeWidget { border: 1px solid #d0d9d6; border-radius: 8px; background: white; selection-background-color: #dce8ff; }
            QTabWidget::pane { border: 1px solid #d0d9d6; border-radius: 8px; background: white; }
            QTabBar::tab { padding: 7px 12px; border: 1px solid transparent; border-top-left-radius: 6px; border-top-right-radius: 6px; }
            QTabBar::tab:selected { background: white; border-color: #d0d9d6; color: #245fc7; font-weight: 650; }
            """
        )

    def section_widget(self, title: str, profiles: list[SSHProfile], kind: str) -> QWidget:
        section = QWidget()
        layout = QVBoxLayout(section)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)

        header = QHBoxLayout()
        label = QLabel(f"{title}  {len(profiles)}")
        label.setStyleSheet("color: #69736f; font-size: 12px; font-weight: 700;")
        header.addWidget(label, 1)
        layout.addLayout(header)

        if not profiles:
            empty = QLabel("还没有配置")
            empty.setStyleSheet("color: #8a9691; padding: 6px;")
            layout.addWidget(empty)
        else:
            for profile in profiles:
                row = ProfileRow(profile, self.store.selected_profile_id == profile.id, self.is_profile_active(profile))
                row.clicked.connect(self.select_profile)
                row.edit_clicked.connect(self.edit_profile_by_id)
                layout.addWidget(row)
        return section

    def refresh_sidebar(self) -> None:
        clear_layout(self.profile_layout)
        self.profile_layout.addWidget(self.section_widget("Jupyter 工作区", self.store.profiles_for("jupyter"), "jupyter"))
        self.profile_layout.addWidget(self.section_widget("RStudio 工作区", self.store.profiles_for("rstudio"), "rstudio"))
        self.profile_layout.addWidget(self.section_widget("终端工作区", self.store.profiles_for("terminal"), "terminal"))
        self.profile_layout.addWidget(self.section_widget("SFTP 工作区", self.store.profiles_for("sftp"), "sftp"))
        self.profile_layout.addStretch(1)

    def is_profile_active(self, profile: SSHProfile) -> bool:
        if profile.is_web_workspace:
            return self.tunnel_profile_id == profile.id and self.tunnel_status in {"connecting", "connected"}
        if profile.workspaceKind == "sftp":
            return False
        return self.terminal_profile_id == profile.id and self.terminal_status in {"connecting", "connected"}

    def select_profile(self, profile_id: str) -> None:
        self.store.selected_profile_id = profile_id
        self.refresh_sidebar()
        self.render_selected_profile()

    def selected_profile(self) -> SSHProfile | None:
        return self.store.selected()

    def render_selected_profile(self) -> None:
        clear_layout(self.detail_layout)
        self.current_webview = None
        profile = self.selected_profile()
        if profile is None:
            empty = QLabel("未选择配置")
            empty.setAlignment(Qt.AlignCenter)
            self.detail_layout.addWidget(empty)
            return
        if profile.is_web_workspace:
            self.render_web_workspace(profile)
        elif profile.workspaceKind == "sftp":
            self.render_sftp_workspace(profile)
        else:
            self.render_terminal(profile)

    def header(self, profile: SSHProfile, status_text: str, color: str) -> QWidget:
        frame = QFrame()
        frame.setStyleSheet("background: rgba(255,255,255,0.92); border-bottom: 1px solid #d9dfdd;")
        layout = QHBoxLayout(frame)
        layout.setContentsMargins(12, 10, 12, 10)
        layout.setSpacing(10)
        layout.addWidget(make_logo(34))
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        top = QHBoxLayout()
        name = QLabel(profile.name)
        name.setStyleSheet("font-size: 18px; font-weight: 750;")
        top.addWidget(name)
        top.addWidget(StatusPill(status_text, color))
        top.addStretch(1)
        detail = QLabel(profile.local_url if profile.is_web_workspace else (profile.target_address or "未填写目标主机"))
        detail.setStyleSheet("color: #6b7280;")
        title_box.addLayout(top)
        title_box.addWidget(detail)
        layout.addLayout(title_box, 1)
        return frame

    def set_primary(self, button: QPushButton) -> QPushButton:
        button.setProperty("primary", True)
        button.style().unpolish(button)
        button.style().polish(button)
        return button

    def render_web_workspace(self, profile: SSHProfile) -> None:
        status_text = {
            "disconnected": "未连接",
            "connecting": "连接中",
            "connected": "已连接",
            "failed": "连接失败",
        }.get(self.tunnel_status, "未连接")
        self.detail_layout.addWidget(self.header(profile, status_text, status_color(self.tunnel_status)))

        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(12, 10, 12, 12)
        layout.setSpacing(10)

        controls = QHBoxLayout()
        if self.tunnel_profile_id != profile.id:
            workspace_status_text = f"{profile.workspace_title} 未连接"
            workspace_status_color = "#64706b"
        elif self.tunnel_status == "connecting":
            workspace_status_text = f"{profile.workspace_title} 正在连接"
            workspace_status_color = "#b96200"
        elif self.tunnel_status == "connected":
            workspace_status_text = f"{profile.workspace_title} 已连接"
            workspace_status_color = "#158a4b"
        elif self.tunnel_status == "failed":
            workspace_status_text = f"{profile.workspace_title} 连接失败"
            workspace_status_color = "#c23535"
        else:
            workspace_status_text = f"{profile.workspace_title} 未连接"
            workspace_status_color = "#64706b"
        tabs_label = StatusPill(
            workspace_status_text,
            workspace_status_color,
        )
        controls.addWidget(tabs_label)
        controls.addStretch(1)
        config = QPushButton("配置")
        config.clicked.connect(lambda: self.edit_profile(profile))
        controls.addWidget(config)
        reload_button = QPushButton("刷新")
        reload_button.clicked.connect(lambda: self.load_web_url(profile))
        reload_button.setEnabled(self.tunnel_profile_id == profile.id and self.tunnel_status == "connected")
        controls.addWidget(reload_button)
        connect = QPushButton("断开" if self.is_profile_active(profile) else "连接")
        connect.clicked.connect(lambda: self.disconnect_tunnel() if self.is_profile_active(profile) else self.connect_tunnel(profile))
        controls.addWidget(self.set_primary(connect))
        layout.addLayout(controls)

        tabs = QTabWidget()
        browser = QWidget()
        browser_layout = QVBoxLayout(browser)
        browser_layout.setContentsMargins(0, 0, 0, 0)
        if QWebEngineView is not None and self.tunnel_profile_id == profile.id and self.tunnel_status == "connected":
            self.current_webview = QWebEngineView()
            browser_layout.addWidget(self.current_webview, 1)
            self.load_web_url(profile)
        elif QWebEngineView is not None:
            placeholder = QLabel(f"连接成功后，这里会显示 {profile.workspace_title}")
            placeholder.setAlignment(Qt.AlignCenter)
            placeholder.setStyleSheet("color: #6b7280; background: white; border-radius: 8px;")
            browser_layout.addWidget(placeholder, 1)
        else:
            fallback = QFrame()
            fallback_layout = QVBoxLayout(fallback)
            fallback_layout.setAlignment(Qt.AlignCenter)
            message = QLabel(f"未安装 Qt WebEngine，{profile.workspace_title} 将使用系统默认浏览器打开。")
            message.setStyleSheet("color: #6b7280;")
            open_button = QPushButton("打开浏览器")
            open_button.clicked.connect(lambda: webbrowser.open(profile.local_url))
            fallback_layout.addWidget(message)
            fallback_layout.addWidget(open_button, 0, Qt.AlignCenter)
            browser_layout.addWidget(fallback, 1)
        tabs.addTab(browser, profile.workspace_title)

        log = QPlainTextEdit()
        log.setReadOnly(True)
        log.setPlainText(self.tunnel_log_text or "暂无日志。")
        log.setFont(QFont("Consolas", 10))
        self.tunnel_log_widget = log
        tabs.addTab(log, "日志")
        layout.addWidget(tabs, 1)
        self.detail_layout.addWidget(container, 1)

    def connect_tunnel(self, profile: SSHProfile) -> None:
        self.disconnect_tunnel(update_ui=False)
        self.tunnel_profile_id = profile.id
        self.tunnel_status = "connecting"
        self.tunnel_log_text = ""
        self.tunnel = TunnelServer(profile, self.bridge.tunnel_log.emit, self.bridge.tunnel_status.emit)
        self.tunnel.start()
        self.refresh_sidebar()
        self.render_selected_profile()

    def disconnect_tunnel(self, update_ui: bool = True) -> None:
        if self.tunnel is not None:
            self.tunnel.stop()
            self.tunnel = None
        self.tunnel_profile_id = None
        self.tunnel_status = "disconnected"
        if update_ui:
            self.refresh_sidebar()
            self.render_selected_profile()

    def append_tunnel_log(self, text: str) -> None:
        self.tunnel_log_text = (self.tunnel_log_text + text.rstrip() + "\n")[-80000:]
        widget = getattr(self, "tunnel_log_widget", None)
        if widget is not None:
            widget.setPlainText(self.tunnel_log_text)
            widget.moveCursor(QTextCursor.End)

    def handle_tunnel_status(self, status: str, message: object) -> None:
        old = self.tunnel_status
        self.tunnel_status = status
        self.tunnel_message = str(message) if message else None
        if status == "connected" and old != "connected":
            active = next((item for item in self.store.profiles if item.id == self.tunnel_profile_id), self.selected_profile())
            if active is not None:
                if QWebEngineView is None:
                    webbrowser.open(active.local_url)
                else:
                    QTimer.singleShot(100, lambda: self.load_web_url(active))
        if status == "failed":
            self.tunnel_profile_id = None
        self.refresh_sidebar()
        self.render_selected_profile()

    def load_web_url(self, profile: SSHProfile) -> None:
        if self.current_webview is not None:
            self.current_webview.load(QUrl(profile.local_url))
        elif QWebEngineView is None:
            webbrowser.open(profile.local_url)

    def render_sftp_workspace(self, profile: SSHProfile) -> None:
        states = self.ensure_sftp_workspace_tabs(profile)
        header = QFrame()
        header.setStyleSheet("background: rgba(255,255,255,0.92); border-bottom: 1px solid #d9dfdd;")
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(12, 7, 12, 7)
        header_layout.setSpacing(8)
        header_layout.addWidget(make_logo(30))

        name = QLabel(profile.name)
        name.setStyleSheet("font-size: 17px; font-weight: 750;")
        header_layout.addWidget(name)
        header_layout.addWidget(StatusPill(f"{len(states)} 个标签", "#245fc7"))

        detail = QLabel("默认本地，可在标签内选择终端工作区或自定义 SFTP")
        detail.setStyleSheet("color: #6b7280; font-size: 12px;")
        header_layout.addWidget(detail, 1)

        config = QPushButton("配置")
        config.clicked.connect(lambda: self.edit_profile(profile))
        header_layout.addWidget(config)
        self.detail_layout.addWidget(header)

        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        tabs = QTabWidget()
        tabs.setTabsClosable(True)
        tabs.tabCloseRequested.connect(lambda index, selected_profile=profile: self.close_sftp_tab(selected_profile, index))
        tabs.currentChanged.connect(lambda index, selected_profile=profile: self.remember_sftp_tab_index(selected_profile, index))
        for state in states:
            tabs.addTab(self.sftp_tab_widget(profile, state), state.title)

        selected_index = self.sftp_workspace_selected_tab_by_profile.get(profile.id, 0)
        if states:
            tabs.setCurrentIndex(max(0, min(selected_index, len(states) - 1)))

        add_tab = QToolButton()
        add_tab.setText("+")
        add_tab.setToolTip("新增 SFTP 标签")
        add_tab.clicked.connect(lambda _checked=False, selected_profile=profile: self.add_sftp_tab(selected_profile))
        tabs.setCornerWidget(add_tab, Qt.TopRightCorner)

        layout.addWidget(tabs, 1)
        self.detail_layout.addWidget(container, 1)

    def sftp_source_profiles(self) -> list[SSHProfile]:
        return [profile for profile in self.store.profiles if profile.workspaceKind in {"terminal", "sftp"}]

    def ensure_sftp_workspace_tabs(self, profile: SSHProfile) -> list[SFTPTabState]:
        states = self.sftp_workspace_tabs_by_profile.get(profile.id)
        if not states:
            states = [SFTPTabState.local()]
        source_ids = {item.id for item in self.sftp_source_profiles()}
        for state in states:
            if state.source_kind == "remote" and state.profile_id not in source_ids:
                state.source_kind = None
                state.profile_id = None
                state.title = "选择主机"
                state.entries = []
                state.current_path = str(Path.home())
                state.status = "选择主机"
        self.sftp_workspace_tabs_by_profile[profile.id] = states
        return states

    def sftp_tab_widget(self, workspace_profile: SSHProfile, state: SFTPTabState) -> QWidget:
        if state.source_kind == "local":
            return LocalSFTPPaneWidget(self, state)
        if state.source_kind == "remote":
            return SFTPPaneWidget(self, state, state.title, show_profile_combo=False)
        return self.sftp_host_picker_widget(workspace_profile, state)

    def sftp_host_picker_widget(self, workspace_profile: SSHProfile, state: SFTPTabState) -> QWidget:
        widget = QScrollArea()
        widget.setWidgetResizable(True)
        widget.setFrameShape(QFrame.NoFrame)
        holder = QWidget()
        layout = QVBoxLayout(holder)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(14)

        title = QLabel("Hosts")
        title.setStyleSheet("font-size: 20px; font-weight: 780; color: #111827;")
        layout.addWidget(title)

        grid_holder = QWidget()
        grid = QGridLayout(grid_holder)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(14)

        sources = [("local", None, "127.0.0.1", "本地主机")]
        for source in self.sftp_source_profiles():
            subtitle = source.target_address or "未填写目标主机"
            sources.append(("remote", source.id, source.name, subtitle))

        for index, (kind, profile_id, name, subtitle) in enumerate(sources):
            card = QPushButton()
            card.setCursor(Qt.PointingHandCursor)
            card.setMinimumHeight(86)
            card.setStyleSheet(
                """
                QPushButton {
                    text-align: left;
                    padding: 14px 18px;
                    border-radius: 8px;
                    border: 1px solid #d6dfdc;
                    background: white;
                    font-size: 15px;
                    font-weight: 700;
                }
                QPushButton:hover {
                    border-color: #2b85ee;
                    background: #f7fbff;
                }
                """
            )
            card.setText(f"{name}\n{subtitle}")
            card.clicked.connect(
                lambda _checked=False, selected_kind=kind, selected_profile_id=profile_id, selected_name=name: self.select_sftp_tab_source(
                    workspace_profile,
                    state,
                    selected_kind,
                    selected_profile_id,
                    selected_name,
                )
            )
            grid.addWidget(card, index // 2, index % 2)

        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        layout.addWidget(grid_holder)
        layout.addStretch(1)
        widget.setWidget(holder)
        return widget

    def select_sftp_tab_source(
        self,
        workspace_profile: SSHProfile,
        state: SFTPTabState,
        kind: str,
        profile_id: str | None,
        title: str,
    ) -> None:
        state.source_kind = kind
        state.profile_id = profile_id
        state.title = title
        state.entries = []
        state.filter_text = ""
        state.pending_path = None
        state.current_path = str(Path.home()) if kind == "local" else "."
        state.status = "本地文件" if kind == "local" else "文件空闲"
        self.render_selected_profile()

    def add_sftp_tab(self, profile: SSHProfile) -> None:
        states = self.ensure_sftp_workspace_tabs(profile)
        states.append(SFTPTabState.empty())
        self.sftp_workspace_selected_tab_by_profile[profile.id] = len(states) - 1
        self.render_selected_profile()

    def close_sftp_tab(self, profile: SSHProfile, index: int) -> None:
        states = self.ensure_sftp_workspace_tabs(profile)
        if len(states) <= 1 or index < 0 or index >= len(states):
            return
        states.pop(index)
        current = self.sftp_workspace_selected_tab_by_profile.get(profile.id, 0)
        self.sftp_workspace_selected_tab_by_profile[profile.id] = max(0, min(current, len(states) - 1))
        self.render_selected_profile()

    def remember_sftp_tab_index(self, profile: SSHProfile, index: int) -> None:
        if index >= 0:
            self.sftp_workspace_selected_tab_by_profile[profile.id] = index

    def render_terminal(self, profile: SSHProfile) -> None:
        status_text = {
            "disconnected": "终端未连接",
            "connecting": "终端连接中",
            "connected": "终端已连接",
            "failed": "终端失败",
        }.get(self.terminal_status, "终端未连接")
        self.detail_layout.addWidget(self.header(profile, status_text, status_color(self.terminal_status)))

        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(12, 10, 12, 12)
        layout.setSpacing(10)

        controls = QHBoxLayout()
        config = QPushButton("配置")
        config.clicked.connect(lambda: self.edit_profile(profile))
        controls.addWidget(config)
        file_toggle = QPushButton("隐藏文件" if self.file_sidebar_visible else "文件")
        file_toggle.clicked.connect(lambda: self.toggle_file_sidebar(profile))
        controls.addWidget(file_toggle)
        if self.file_sidebar_visible:
            refresh_files = QPushButton("刷新文件")
            refresh_files.clicked.connect(lambda: self.refresh_files(profile))
            controls.addWidget(refresh_files)
        native = QPushButton("原生终端")
        native.clicked.connect(lambda: self.open_native_terminal(profile))
        controls.addWidget(native)
        controls.addStretch(1)
        connect = QPushButton("断开终端" if self.is_profile_active(profile) else "连接终端")
        connect.clicked.connect(lambda: self.disconnect_terminal() if self.is_profile_active(profile) else self.connect_terminal(profile))
        controls.addWidget(self.set_primary(connect))
        layout.addLayout(controls)

        splitter = QSplitter(Qt.Horizontal)
        splitter.setChildrenCollapsible(False)
        splitter.addWidget(self.terminal_pane(profile))
        splitter.setStretchFactor(0, 1)
        if self.file_sidebar_visible:
            splitter.addWidget(self.file_pane(profile))
            splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, 1)
        self.detail_layout.addWidget(container, 1)

    def toggle_file_sidebar(self, profile: SSHProfile) -> None:
        self.file_sidebar_visible = not self.file_sidebar_visible
        self.render_selected_profile()
        if self.file_sidebar_visible:
            self.refresh_files(profile)

    def terminal_pane(self, profile: SSHProfile) -> QWidget:
        pane = QFrame()
        pane.setStyleSheet("QFrame { background: white; border: 1px solid #d1d8d6; border-radius: 8px; }")
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        top = QHBoxLayout()
        title = QLabel("SSH 终端")
        title.setStyleSheet("font-weight: 700;")
        top.addWidget(title)
        top.addWidget(StatusPill("可直接输入" if self.is_profile_active(profile) else "未连接", "#1f9d55" if self.is_profile_active(profile) else "#6b7280"))
        top.addStretch(1)
        clear = QPushButton("清空")
        clear.clicked.connect(self.clear_terminal)
        top.addWidget(clear)
        ctrl_c = QPushButton("中断")
        ctrl_c.clicked.connect(lambda: self.send_terminal_text("\x03"))
        top.addWidget(ctrl_c)
        layout.addLayout(top)

        self.terminal_widget = QPlainTextEdit()
        self.terminal_widget.setPlainText(self.terminal_text)
        self.terminal_widget.setFont(QFont("Consolas", 10))
        self.terminal_widget.setStyleSheet("background: #101418; color: #e4e8ec; border-radius: 6px;")
        self.terminal_widget.moveCursor(QTextCursor.End)
        layout.addWidget(self.terminal_widget, 1)

        command_row = QHBoxLayout()
        self.command_input = QLineEdit()
        self.command_input.setPlaceholderText("输入命令后回车")
        self.command_input.returnPressed.connect(self.send_command_line)
        command_row.addWidget(self.command_input, 1)
        send = QPushButton("发送")
        send.clicked.connect(self.send_command_line)
        command_row.addWidget(send)
        layout.addLayout(command_row)
        return pane

    def file_pane(self, profile: SSHProfile) -> QWidget:
        pane = QFrame()
        pane.setStyleSheet("QFrame { background: white; border: 1px solid #d1d8d6; border-radius: 8px; }")
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        top = QHBoxLayout()
        title = QLabel(profile.targetHost or "远程服务器")
        title.setStyleSheet("font-weight: 700;")
        top.addWidget(title)
        self.sftp_status_pill = StatusPill(self.sftp_status, status_color(self.sftp_status))
        top.addWidget(self.sftp_status_pill)
        top.addStretch(1)
        self.filter_input = QLineEdit()
        self.filter_input.setPlaceholderText("筛选")
        self.filter_input.textChanged.connect(self.populate_file_tree)
        self.filter_input.setMaximumWidth(160)
        top.addWidget(self.filter_input)
        menu_button = QToolButton()
        menu_button.setText("操作")
        menu_button.setPopupMode(QToolButton.InstantPopup)
        menu = QMenu(menu_button)
        menu.addAction("刷新", lambda: self.refresh_files(profile))
        menu.addAction("上级文件夹", lambda: self.go_parent(profile))
        menu.addSeparator()
        menu.addAction("上传文件", lambda: self.choose_upload_files(profile))
        menu.addAction("上传文件夹", lambda: self.choose_upload_folder(profile))
        menu.addAction("下载选中项", lambda: self.download_selected(profile))
        menu.addAction("新建文件夹", lambda: self.create_remote_folder(profile))
        menu.addSeparator()
        menu.addAction("复制到目标目录", lambda: self.copy_selected_to_directory(profile))
        menu.addAction("重命名", lambda: self.rename_selected_remote(profile))
        menu.addAction("修改权限", lambda: self.edit_selected_permissions(profile))
        menu.addAction("删除", lambda: self.delete_selected_remote(profile))
        menu_button.setMenu(menu)
        top.addWidget(menu_button)
        layout.addLayout(top)

        path_row = QHBoxLayout()
        up = QPushButton("上级")
        up.clicked.connect(lambda: self.go_parent(profile))
        path_row.addWidget(up)
        self.remote_path_input = QLineEdit(self.current_remote_path)
        self.remote_path_input.returnPressed.connect(lambda: self.refresh_files(profile, self.remote_path_input.text()))
        path_row.addWidget(self.remote_path_input, 1)
        open_path = QPushButton("打开")
        open_path.clicked.connect(lambda: self.refresh_files(profile, self.remote_path_input.text()))
        path_row.addWidget(open_path)
        layout.addLayout(path_row)

        self.file_tree = RemoteFileTree()
        self.file_tree.drag_profile_id = profile.id
        self.file_tree.setHeaderLabels(["名称", "修改时间", "大小", "类型"])
        self.file_tree.setColumnWidth(0, 260)
        self.file_tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected_remote(profile))
        self.file_tree.dropped_paths.connect(lambda paths: self.upload_paths(profile, paths))
        self.file_tree.remote_dropped.connect(lambda payload: self.handle_remote_tree_drop(profile, payload))
        self.file_tree.context_requested.connect(lambda item, point: self.show_file_context_menu(profile, item, point))
        layout.addWidget(self.file_tree, 1)
        self.populate_file_tree()
        return pane

    def connect_terminal(self, profile: SSHProfile) -> None:
        self.disconnect_terminal(update_ui=False)
        self.terminal_profile_id = profile.id
        self.terminal_status = "connecting"
        self.terminal_text = ""
        self.terminal = TerminalSession(profile, self.bridge.terminal_output.emit, self.bridge.terminal_status.emit)
        self.terminal.start()
        self.refresh_sidebar()
        self.render_selected_profile()

    def disconnect_terminal(self, update_ui: bool = True) -> None:
        if self.terminal is not None:
            self.terminal.close()
            self.terminal = None
        self.terminal_profile_id = None
        self.terminal_status = "disconnected"
        if update_ui:
            self.refresh_sidebar()
            self.render_selected_profile()

    def append_terminal_output(self, text: str) -> None:
        self.terminal_text = (self.terminal_text + text)[-100000:]
        widget = getattr(self, "terminal_widget", None)
        if widget is not None:
            widget.setPlainText(self.terminal_text)
            widget.moveCursor(QTextCursor.End)

    def handle_terminal_status(self, status: str, message: object) -> None:
        self.terminal_status = status
        if status in {"failed", "disconnected"}:
            self.terminal_profile_id = None
        if message:
            self.append_terminal_output(str(message) + "\n")
        self.refresh_sidebar()
        self.render_selected_profile()

    def clear_terminal(self) -> None:
        self.terminal_text = ""
        widget = getattr(self, "terminal_widget", None)
        if widget is not None:
            widget.clear()

    def send_terminal_text(self, text: str) -> None:
        if self.terminal is None or self.terminal_status != "connected":
            QMessageBox.information(self, APP_NAME, "请先连接终端。")
            return
        self.terminal.send(text)

    def send_command_line(self) -> None:
        text = self.command_input.text()
        if not text:
            return
        self.send_terminal_text(text + "\n")
        self.command_input.clear()

    def open_native_terminal(self, profile: SSHProfile) -> None:
        command = subprocess.list2cmdline(["ssh"] + profile.terminal_ssh_args(include_batch_mode=False))
        try:
            creation_flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
            if sys.platform == "win32":
                subprocess.Popen(["cmd.exe", "/k", command], creationflags=creation_flags)
            else:
                QMessageBox.information(self, APP_NAME, command)
        except Exception as exc:
            QMessageBox.critical(self, APP_NAME, f"打开原生终端失败：{exc}")

    def show_file_context_menu(self, profile: SSHProfile, item: object, global_point: object) -> None:
        entry = self.remote_entry_for_item(item)
        menu = QMenu(self)

        if entry is None:
            menu.addAction("刷新", lambda: self.refresh_files(profile))
            menu.addAction("新建文件夹", lambda: self.create_remote_folder(profile))
            menu.addSeparator()
            menu.addAction("上传文件", lambda: self.choose_upload_files(profile))
            menu.addAction("上传文件夹", lambda: self.choose_upload_folder(profile))
            menu.exec(global_point)
            return

        is_parent = entry.name == ".."
        menu.addAction("打开", lambda: self.open_remote_entry(profile, entry))
        download_action = menu.addAction("下载到本地", lambda: self.download_remote_entry(profile, entry))
        menu.addSeparator()
        copy_action = menu.addAction("复制到目标目录", lambda: self.copy_remote_entry(profile, entry))
        rename_action = menu.addAction("重命名", lambda: self.rename_remote_entry(profile, entry))
        delete_action = menu.addAction("删除", lambda: self.delete_remote_entry(profile, entry))
        menu.addSeparator()
        menu.addAction("刷新", lambda: self.refresh_files(profile))
        menu.addAction("新建文件夹", lambda: self.create_remote_folder(profile))
        chmod_action = menu.addAction("修改权限", lambda: self.edit_remote_permissions(profile, entry))

        for action in (download_action, copy_action, rename_action, delete_action, chmod_action):
            action.setEnabled(not is_parent and self.sftp_status not in {"文件处理中", "文件同步中", "正在上传", "正在下载", "正在打开"})

        menu.exec(global_point)

    def close_sftp_connection(self, profile_id: str | None = None) -> None:
        with self.sftp_connection_guard:
            if profile_id is None:
                connections = list(self.sftp_connections.values())
                self.sftp_connections.clear()
            else:
                connection = self.sftp_connections.pop(profile_id, None)
                connections = [connection] if connection is not None else []
        for connection in connections:
            try:
                connection.close()
            except Exception:
                pass

    def sftp_lock_for(self, profile_id: str) -> threading.RLock:
        with self.sftp_connection_guard:
            lock = self.sftp_locks.get(profile_id)
            if lock is None:
                lock = threading.RLock()
                self.sftp_locks[profile_id] = lock
            return lock

    def ensure_sftp_connection(self, profile: SSHProfile):
        connection = self.sftp_connections.get(profile.id)
        if connection is not None:
            transport = connection.target.get_transport()
            if transport is not None and transport.is_active():
                return connection
            self.close_sftp_connection(profile.id)

        connection = connect_ssh(profile)
        transport = connection.target.get_transport()
        if transport is not None and profile.keepAliveEnabled:
            transport.set_keepalive(max(10, min(profile.keepAliveInterval, 600)))
        with self.sftp_connection_guard:
            self.sftp_connections[profile.id] = connection
        return connection

    def run_with_sftp(self, profile: SSHProfile, action: Callable):
        with self.sftp_lock_for(profile.id):
            connection = self.ensure_sftp_connection(profile)
            sftp = connection.target.open_sftp()
            try:
                return action(sftp, connection)
            except Exception:
                self.close_sftp_connection(profile.id)
                raise
            finally:
                try:
                    sftp.close()
                except Exception:
                    pass

    def run_remote_shell(self, profile: SSHProfile, script: str) -> str:
        def action(_sftp, connection) -> str:
            command = "sh -lc " + shlex.quote(script)
            _stdin, stdout, stderr = connection.target.exec_command(command)
            exit_code = stdout.channel.recv_exit_status()
            output = stdout.read().decode("utf-8", errors="replace")
            error = stderr.read().decode("utf-8", errors="replace")
            if exit_code != 0:
                raise RuntimeError((error or output or f"远程命令失败，状态码：{exit_code}").strip())
            return output

        return self.run_with_sftp(profile, action)

    def run_file_operation(self, profile: SSHProfile, status: str, worker: Callable, refresh_path: str | None = None) -> None:
        self.bridge.sftp_status.emit(status)

        def work() -> None:
            try:
                worker()
                if refresh_path is None:
                    self.bridge.sftp_status.emit("文件完成")
                else:
                    self.invalidate_directory_cache(profile, refresh_path)
                    entries, actual = self.list_remote_directory(profile, refresh_path)
                    self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPOperation", daemon=True).start()

    def refresh_files(self, profile: SSHProfile, path: str | None = None) -> None:
        remote_path = (path or self.current_remote_path or ".").strip() or "."
        self.begin_remote_navigation(profile, remote_path)

        def work() -> None:
            try:
                entries, actual = self.list_remote_directory(profile, remote_path)
                self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPList", daemon=True).start()

    def begin_remote_navigation(self, profile: SSHProfile, remote_path: str) -> None:
        self.sftp_status = "文件同步中"
        cache_key = self.directory_cache_key(profile, remote_path)
        cached = self.directory_cache.get(cache_key)
        if cached is not None:
            entries, actual = cached
            self.remote_entries = list(entries)
            self.current_remote_path = actual
        else:
            self.current_remote_path = remote_path
            parent = self.parent_remote_entry(remote_path)
            self.remote_entries = [parent] if parent is not None else []
        self.update_file_widgets()

    def directory_cache_key(self, profile: SSHProfile, path: str) -> tuple[str, str]:
        normalized = (path or ".").strip() or "."
        return profile.id, normalized

    def invalidate_directory_cache(self, profile: SSHProfile, path: str) -> None:
        self.directory_cache.pop(self.directory_cache_key(profile, path), None)

    def parent_remote_entry(self, path: str) -> RemoteFileEntry | None:
        trimmed = (path or ".").strip()
        if not trimmed or trimmed in {".", "/", "~"}:
            return None
        return RemoteFileEntry(
            name="..",
            path=posixpath.dirname(trimmed.rstrip("/")) or "/",
            is_dir=True,
            is_link=False,
            permissions="上级目录",
            size="",
            modified="",
        )

    def list_remote_directory(self, profile: SSHProfile, path: str) -> tuple[list[RemoteFileEntry], str]:
        def action(sftp, _connection) -> tuple[list[RemoteFileEntry], str]:
            actual = sftp.normalize(path)
            attrs = sftp.listdir_attr(actual)
            parent_entries: list[RemoteFileEntry] = []
            child_entries: list[RemoteFileEntry] = []
            if actual not in {".", "/"}:
                parent_entries.append(
                    RemoteFileEntry(
                        name="..",
                        path=posixpath.dirname(actual.rstrip("/")) or "/",
                        is_dir=True,
                        is_link=False,
                        permissions="上级目录",
                        size="",
                        modified="",
                    )
                )
            for attr in attrs:
                mode = attr.st_mode or 0
                is_dir = stat.S_ISDIR(mode)
                is_link = stat.S_ISLNK(mode)
                child_entries.append(
                    RemoteFileEntry(
                        name=attr.filename,
                        path=posixpath.join(actual, attr.filename) if actual != "/" else "/" + attr.filename,
                        is_dir=is_dir,
                        is_link=is_link,
                        permissions=stat.filemode(mode),
                        size="--" if is_dir else bytes_label(attr.st_size or 0),
                        modified=time.strftime("%Y-%m-%d %H:%M", time.localtime(attr.st_mtime or 0)),
                    )
                )
            child_entries.sort(key=lambda item: (not item.is_dir, item.name.lower()))
            return parent_entries + child_entries, actual

        return self.run_with_sftp(profile, action)

    def handle_sftp_done(self, entries: list, actual: str) -> None:
        self.remote_entries = list(entries)
        self.current_remote_path = actual
        if self.store.selected() is not None:
            profile = self.store.selected()
            if profile is not None:
                self.directory_cache[self.directory_cache_key(profile, actual)] = (list(entries), actual)
        self.sftp_status = "文件完成"
        self.update_file_widgets()

    def handle_sftp_error(self, message: str) -> None:
        self.sftp_status = "文件失败"
        QMessageBox.critical(self, APP_NAME, message)
        self.update_file_widgets()

    def handle_sftp_status(self, status: str) -> None:
        self.sftp_status = status
        self.update_file_widgets()

    def profile_by_id(self, profile_id: str) -> SSHProfile | None:
        return next((profile for profile in self.store.profiles if profile.id == profile_id), None)

    def make_remote_file_item(self, entry: RemoteFileEntry) -> RemoteFileTreeItem:
        item = RemoteFileTreeItem([entry.name, entry.modified, entry.size, entry.kind])
        item.setData(0, Qt.UserRole, entry.path)
        item.setData(0, Qt.UserRole + 1, entry.is_dir)
        item.setData(0, Qt.UserRole + 2, entry.name.lower())
        item.setData(0, Qt.UserRole + 3, entry.modified)
        item.setData(0, Qt.UserRole + 4, self.size_label_to_bytes(entry.size))
        item.setData(0, Qt.UserRole + 5, entry.kind)
        item.setData(0, Qt.UserRole + 6, entry.name == "..")
        return item

    def remote_entry_for_item_in_entries(self, item: object, entries: list[RemoteFileEntry]) -> RemoteFileEntry | None:
        if item is None:
            return None
        try:
            path = item.data(0, Qt.UserRole)
        except Exception:
            return None
        return next((entry for entry in entries if entry.path == path), None)

    def populate_file_tree(self) -> None:
        tree = getattr(self, "file_tree", None)
        if tree is None:
            return
        needle = ""
        if hasattr(self, "filter_input"):
            needle = self.filter_input.text().strip().lower()
        tree.clear()
        for entry in self.remote_entries:
            if needle and needle not in entry.name.lower():
                continue
            tree.addTopLevelItem(self.make_remote_file_item(entry))

    def update_file_widgets(self) -> None:
        path_input = getattr(self, "remote_path_input", None)
        if path_input is not None and path_input.text() != self.current_remote_path:
            path_input.setText(self.current_remote_path)
        pill = getattr(self, "sftp_status_pill", None)
        if pill is not None:
            pill.setText(self.sftp_status)
            pill.set_color(status_color(self.sftp_status))
        self.populate_file_tree()

    def size_label_to_bytes(self, value: str) -> int:
        text = (value or "").strip()
        if not text or text == "--":
            return -1
        parts = text.split()
        if not parts:
            return -1
        try:
            number = float(parts[0])
        except ValueError:
            return -1
        unit = parts[1].upper() if len(parts) > 1 else "B"
        multiplier = {
            "B": 1,
            "KB": 1024,
            "MB": 1024 ** 2,
            "GB": 1024 ** 3,
            "TB": 1024 ** 4,
        }.get(unit, 1)
        return int(number * multiplier)

    def selected_remote_entry(self) -> RemoteFileEntry | None:
        tree = getattr(self, "file_tree", None)
        if tree is None:
            return None
        items = tree.selectedItems()
        if not items:
            return None
        path = items[0].data(0, Qt.UserRole)
        return next((entry for entry in self.remote_entries if entry.path == path), None)

    def remote_entry_for_item(self, item: object) -> RemoteFileEntry | None:
        return self.remote_entry_for_item_in_entries(item, self.remote_entries)

    def open_selected_remote(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is not None:
            self.open_remote_entry(profile, entry)

    def open_remote_entry(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        if entry.is_dir:
            self.refresh_files(profile, entry.path)
            return

        target_dir = Path(tempfile.mkdtemp(prefix="417ssh-open-"))
        local_path = target_dir / (entry.name or "remote-file")

        def worker() -> None:
            self.download_file_to_path(profile, entry.path, local_path)
            self.open_local_path(local_path)

        self.run_file_operation(profile, "正在打开", worker)

    def open_local_path(self, path: Path) -> None:
        if sys.platform == "win32":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            webbrowser.open(path.as_uri())

    def download_file_to_path(self, profile: SSHProfile, remote_path: str, local_path: Path) -> None:
        def action(sftp, _connection) -> None:
            sftp.get(remote_path, str(local_path))

        self.run_with_sftp(profile, action)

    def selected_mutable_entry(self) -> RemoteFileEntry | None:
        entry = self.selected_remote_entry()
        if entry is None:
            QMessageBox.information(self, APP_NAME, "请先选择一个远程文件或文件夹。")
            return None
        if entry.name == "..":
            QMessageBox.information(self, APP_NAME, "上级目录不能执行这个操作。")
            return None
        return entry

    def copy_selected_to_directory(self, profile: SSHProfile) -> None:
        entry = self.selected_mutable_entry()
        if entry is not None:
            self.copy_remote_entry(profile, entry)

    def rename_selected_remote(self, profile: SSHProfile) -> None:
        entry = self.selected_mutable_entry()
        if entry is not None:
            self.rename_remote_entry(profile, entry)

    def delete_selected_remote(self, profile: SSHProfile) -> None:
        entry = self.selected_mutable_entry()
        if entry is not None:
            self.delete_remote_entry(profile, entry)

    def edit_selected_permissions(self, profile: SSHProfile) -> None:
        entry = self.selected_mutable_entry()
        if entry is not None:
            self.edit_remote_permissions(profile, entry)

    def copy_remote_path(self, profile: SSHProfile, source_path: str, target_dir: str) -> None:
        script = f"""
src={shlex.quote(source_path)}
target_dir={shlex.quote(target_dir)}
if [ ! -e "$src" ] && [ ! -L "$src" ]; then
  printf '源文件不存在：%s' "$src" >&2
  exit 2
fi
if [ ! -d "$target_dir" ]; then
  printf '目标目录不存在：%s' "$target_dir" >&2
  exit 2
fi
base=$(basename "$src")
if [ -e "$target_dir/$base" ] || [ -L "$target_dir/$base" ]; then
  printf '目标目录中已存在：%s' "$base" >&2
  exit 2
fi
cp -a -- "$src" "$target_dir/"
"""
        self.run_remote_shell(profile, script)

    def transfer_remote_payload(self, source_profile: SSHProfile, payload: dict, target_profile: SSHProfile, target_dir: str) -> None:
        source_path = str(payload.get("path") or "")
        name = str(payload.get("name") or posixpath.basename(source_path) or "remote-item")
        is_dir = bool(payload.get("is_dir"))
        if not source_path:
            raise RuntimeError("拖拽来源路径为空。")
        if source_profile.id == target_profile.id:
            self.copy_remote_path(target_profile, source_path, target_dir)
            return

        temp_dir = Path(tempfile.mkdtemp(prefix="417ssh-transfer-"))
        entry = RemoteFileEntry(
            name=name,
            path=source_path,
            is_dir=is_dir,
            is_link=False,
            permissions="",
            size="",
            modified="",
        )
        self.download_path(source_profile, entry, temp_dir)
        self.upload_path(target_profile, temp_dir / name, target_dir)

    def copy_remote_entry(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        target_dir, ok = QInputDialog.getText(self, "复制到目标目录", "输入远程目标目录：", text=self.current_remote_path)
        target_dir = target_dir.strip()
        if not ok or not target_dir:
            return
        self.run_file_operation(
            profile,
            "文件处理中",
            lambda: self.copy_remote_path(profile, entry.path, target_dir),
            self.current_remote_path,
        )

    def rename_remote_entry(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        new_name, ok = QInputDialog.getText(self, "重命名", "输入新的名称：", text=entry.name)
        new_name = new_name.strip()
        if not ok or not new_name or new_name == entry.name:
            return
        if not self.valid_remote_basename(new_name):
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含 /。")
            return
        target_path = self.join_remote_path(posixpath.dirname(entry.path.rstrip("/")) or "/", new_name)

        def worker() -> None:
            def action(sftp, _connection) -> None:
                try:
                    sftp.stat(target_path)
                    raise RuntimeError(f"目标已存在：{target_path}")
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                sftp.rename(entry.path, target_path)

            self.run_with_sftp(profile, action)

        self.run_file_operation(profile, "文件处理中", worker, self.current_remote_path)

    def delete_remote_entry(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        prompt = f"确定删除文件夹“{entry.name}”及其中所有内容吗？" if entry.is_dir else f"确定删除文件“{entry.name}”吗？"
        if QMessageBox.question(self, "删除", prompt) != QMessageBox.Yes:
            return
        self.run_file_operation(
            profile,
            "文件处理中",
            lambda: self.remove_remote_path(profile, entry.path),
            self.current_remote_path,
        )

    def create_remote_folder(self, profile: SSHProfile) -> None:
        folder_name, ok = QInputDialog.getText(self, "新建文件夹", "输入文件夹名称：", text="新建文件夹")
        folder_name = folder_name.strip()
        if not ok or not folder_name:
            return
        if not self.valid_remote_basename(folder_name):
            QMessageBox.warning(self, APP_NAME, "名称不能为空，也不能包含 /。")
            return
        target_path = self.join_remote_path(self.current_remote_path or ".", folder_name)

        def worker() -> None:
            def action(sftp, _connection) -> None:
                try:
                    sftp.stat(target_path)
                    raise RuntimeError(f"目标已存在：{target_path}")
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
                sftp.mkdir(target_path)

            self.run_with_sftp(profile, action)

        self.run_file_operation(profile, "文件处理中", worker, self.current_remote_path)

    def edit_remote_permissions(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        mode, ok = QInputDialog.getText(
            self,
            "修改权限",
            "输入 chmod 权限，例如 755、664 或 u+x：",
            text=self.default_permission_mode(entry),
        )
        mode = mode.strip()
        if not ok or not mode:
            return
        script = f"chmod {shlex.quote(mode)} -- {shlex.quote(entry.path)}"
        self.run_file_operation(
            profile,
            "文件处理中",
            lambda: self.run_remote_shell(profile, script),
            self.current_remote_path,
        )

    def remove_remote_path(self, profile: SSHProfile, remote_path: str) -> None:
        def action(sftp, _connection) -> None:
            self.remove_remote_path_with_sftp(sftp, remote_path)

        self.run_with_sftp(profile, action)

    def remove_remote_path_with_sftp(self, sftp, remote_path: str) -> None:
        attr = sftp.lstat(remote_path)
        mode = attr.st_mode or 0
        if stat.S_ISDIR(mode) and not stat.S_ISLNK(mode):
            for child in sftp.listdir_attr(remote_path):
                child_path = self.join_remote_path(remote_path, child.filename)
                self.remove_remote_path_with_sftp(sftp, child_path)
            sftp.rmdir(remote_path)
        else:
            sftp.remove(remote_path)

    def valid_remote_basename(self, name: str) -> bool:
        return bool(name and name not in {".", ".."} and "/" not in name)

    def join_remote_path(self, base: str, name: str) -> str:
        if base == "/":
            return "/" + name
        return posixpath.join(base or ".", name)

    def default_permission_mode(self, entry: RemoteFileEntry) -> str:
        permissions = entry.permissions or ""
        if len(permissions) < 10:
            return "755" if entry.is_dir else "644"
        result = ""
        for offset in (1, 4, 7):
            value = 0
            if permissions[offset] == "r":
                value += 4
            if permissions[offset + 1] == "w":
                value += 2
            if permissions[offset + 2] != "-":
                value += 1
            result += str(value)
        return result

    def go_parent(self, profile: SSHProfile) -> None:
        path = self.current_remote_path.strip()
        if not path or path in {".", "/"}:
            return
        self.refresh_files(profile, posixpath.dirname(path.rstrip("/")) or "/")

    def choose_upload_files(self, profile: SSHProfile) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "选择要上传的文件")
        if paths:
            self.upload_paths(profile, paths)

    def choose_upload_folder(self, profile: SSHProfile) -> None:
        path = QFileDialog.getExistingDirectory(self, "选择要上传的文件夹")
        if path:
            self.upload_paths(profile, [path])

    def upload_paths(self, profile: SSHProfile, paths: list[str]) -> None:
        if not paths:
            return
        remote_dir = self.current_remote_path or "."
        self.bridge.sftp_status.emit("正在上传")

        def work() -> None:
            try:
                for local in paths:
                    self.upload_path(profile, Path(local), remote_dir)
                self.invalidate_directory_cache(profile, remote_dir)
                entries, actual = self.list_remote_directory(profile, remote_dir)
                self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPUpload", daemon=True).start()

    def handle_remote_tree_drop(self, profile: SSHProfile, payload: dict) -> None:
        source_profile = self.profile_by_id(str(payload.get("profile_id") or ""))
        if source_profile is None:
            QMessageBox.warning(self, APP_NAME, "没有找到拖拽来源配置。")
            return
        remote_dir = self.current_remote_path or "."
        self.bridge.sftp_status.emit("正在上传")

        def work() -> None:
            try:
                self.transfer_remote_payload(source_profile, payload, profile, remote_dir)
                self.invalidate_directory_cache(profile, remote_dir)
                entries, actual = self.list_remote_directory(profile, remote_dir)
                self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPRemoteDrop", daemon=True).start()

    def upload_path(self, profile: SSHProfile, local_path: Path, remote_dir: str) -> None:
        def action(sftp, _connection) -> None:
            destination = posixpath.join(remote_dir, local_path.name)
            if local_path.is_dir():
                self.sftp_mkdirs(sftp, destination)
                for root, dirs, files in os.walk(local_path):
                    relative = Path(root).relative_to(local_path)
                    remote_root = destination if str(relative) == "." else posixpath.join(destination, relative.as_posix())
                    self.sftp_mkdirs(sftp, remote_root)
                    for directory in dirs:
                        self.sftp_mkdirs(sftp, posixpath.join(remote_root, directory))
                    for filename in files:
                        sftp.put(str(Path(root) / filename), posixpath.join(remote_root, filename))
            else:
                sftp.put(str(local_path), destination)

        self.run_with_sftp(profile, action)

    def download_selected(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is None:
            QMessageBox.information(self, APP_NAME, "请先选择一个远程文件或文件夹。")
            return
        if entry.name == "..":
            QMessageBox.information(self, APP_NAME, "上级目录不能下载。")
            return
        self.download_remote_entry(profile, entry)

    def download_remote_entry(self, profile: SSHProfile, entry: RemoteFileEntry) -> None:
        target_dir = QFileDialog.getExistingDirectory(self, "选择下载位置")
        if not target_dir:
            return
        self.bridge.sftp_status.emit("正在下载")

        def work() -> None:
            try:
                self.download_path(profile, entry, Path(target_dir))
                self.bridge.sftp_status.emit("文件完成")
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPDownload", daemon=True).start()

    def download_path(self, profile: SSHProfile, entry: RemoteFileEntry, target_dir: Path) -> None:
        def action(sftp, _connection) -> None:
            destination = target_dir / entry.name
            if entry.is_dir:
                self.download_dir(sftp, entry.path, destination)
            else:
                sftp.get(entry.path, str(destination))

        self.run_with_sftp(profile, action)

    def download_dir(self, sftp, remote_dir: str, local_dir: Path) -> None:
        local_dir.mkdir(parents=True, exist_ok=True)
        for attr in sftp.listdir_attr(remote_dir):
            remote_path = posixpath.join(remote_dir, attr.filename)
            local_path = local_dir / attr.filename
            if stat.S_ISDIR(attr.st_mode or 0):
                self.download_dir(sftp, remote_path, local_path)
            else:
                sftp.get(remote_path, str(local_path))

    def sftp_mkdirs(self, sftp, remote_path: str) -> None:
        parts = [part for part in remote_path.split("/") if part]
        current = "/" if remote_path.startswith("/") else "."
        for part in parts:
            current = posixpath.join(current, part) if current != "/" else "/" + part
            try:
                sftp.stat(current)
            except OSError:
                sftp.mkdir(current)

    def open_settings(self) -> None:
        dialog = AppSettingsDialog(
            self.app_settings,
            self.update_status,
            self.latest_release,
            self.update_asset,
            self,
        )
        self.settings_dialog = dialog
        dialog.settings_changed.connect(self.save_settings)
        dialog.check_requested.connect(lambda: self.check_updates(silent=False))
        dialog.install_requested.connect(self.download_and_install_update)
        dialog.finished.connect(lambda _result: self.clear_settings_dialog(dialog))
        dialog.exec()

    def clear_settings_dialog(self, dialog: AppSettingsDialog) -> None:
        if self.settings_dialog is dialog:
            self.settings_dialog = None

    def save_settings(self, settings: dict) -> None:
        self.app_settings = dict(settings)
        save_app_settings(self.app_settings)

    def check_updates(self, silent: bool = False) -> None:
        self.update_check_silent = silent
        self.update_status = "正在检查更新"
        self.update_dialog_refresh()

        def work() -> None:
            try:
                release = fetch_latest_release()
                asset = windows_release_asset(release)
                self.bridge.update_done.emit(release, asset)
            except Exception as exc:
                self.bridge.update_error.emit(str(exc))

        threading.Thread(target=work, name="UpdateCheck", daemon=True).start()

    def handle_update_done(self, release: dict, asset: object) -> None:
        self.latest_release = release
        self.update_asset = asset if isinstance(asset, dict) else None
        version = release_version(release)

        if version and is_version_newer(version, CURRENT_VERSION):
            if self.update_asset is None:
                self.update_status = f"发现新版本 {version}，但 release 里没有 Windows portable .zip 更新包"
            else:
                self.update_status = f"发现新版本 {version}"
        else:
            self.update_status = "已是最新版本"

        self.update_dialog_refresh()

        if not self.update_check_silent and self.update_status == "已是最新版本":
            QMessageBox.information(self, APP_NAME, "当前已经是最新版本。")

    def handle_update_error(self, message: str) -> None:
        if self.update_check_silent:
            self.update_status = "尚未检查更新"
        else:
            self.update_status = f"更新失败：{message}"
            QMessageBox.critical(self, APP_NAME, self.update_status)
        self.update_dialog_refresh()

    def download_and_install_update(self) -> None:
        if self.update_asset is None:
            webbrowser.open(RELEASES_URL)
            return

        self.update_status = "正在下载并准备安装"
        self.update_dialog_refresh()

        def work() -> None:
            try:
                path = download_release_asset(self.update_asset)
                script_path = prepare_windows_update(path)
                self.bridge.update_downloaded.emit(str(script_path))
            except Exception as exc:
                self.bridge.update_error.emit(str(exc))

        threading.Thread(target=work, name="UpdateDownload", daemon=True).start()

    def handle_update_downloaded(self, path_text: str) -> None:
        script_path = Path(path_text)
        self.update_status = "安装脚本已启动，正在重启应用"
        self.update_dialog_refresh()

        try:
            launch_windows_update_script(script_path)
            app = QApplication.instance()
            if app is not None:
                QTimer.singleShot(250, app.quit)
        except Exception as exc:
            QMessageBox.critical(self, APP_NAME, f"启动安装脚本失败：{exc}")

    def handle_update_status(self, status: str) -> None:
        self.update_status = status
        self.update_dialog_refresh()

    def update_dialog_refresh(self) -> None:
        if self.settings_dialog is not None:
            self.settings_dialog.set_update_state(self.update_status, self.latest_release, self.update_asset)

    def add_profile(self, kind: str) -> None:
        previous_profile_id = self.store.selected_profile_id
        profile = self.store.add(kind)
        self.refresh_sidebar()
        if not self.edit_profile(profile):
            self.store.delete_by_id(profile.id, previous_profile_id)
            self.refresh_sidebar()
            self.render_selected_profile()

    def duplicate_profile(self) -> None:
        previous_profile_id = self.store.selected_profile_id
        profile = self.store.duplicate_selected()
        self.refresh_sidebar()
        if profile is not None:
            if not self.edit_profile(profile):
                self.store.delete_by_id(profile.id, previous_profile_id)
                self.refresh_sidebar()
                self.render_selected_profile()

    def delete_profile(self) -> None:
        if QMessageBox.question(self, APP_NAME, "确定删除当前配置吗？") == QMessageBox.Yes:
            self.store.delete_selected()
            self.refresh_sidebar()
            self.render_selected_profile()

    def edit_profile_by_id(self, profile_id: str) -> None:
        profile = next((item for item in self.store.profiles if item.id == profile_id), None)
        if profile is not None:
            self.store.selected_profile_id = profile.id
            self.edit_profile(profile)

    def edit_profile(self, profile: SSHProfile) -> bool:
        dialog = ProfileEditor(profile, self)
        dialog.saved.connect(self.save_profile)
        return dialog.exec() == QDialog.Accepted

    def save_profile(self, profile: SSHProfile) -> None:
        self.close_sftp_connection()
        self.directory_cache = {}
        self.store.update(profile)
        self.store.selected_profile_id = profile.id
        self.refresh_sidebar()
        self.render_selected_profile()

    def closeEvent(self, event) -> None:
        self.disconnect_tunnel(update_ui=False)
        self.disconnect_terminal(update_ui=False)
        self.close_sftp_connection()
        event.accept()


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setWindowIcon(QIcon(str(ASSETS_DIR / "logo.jpg")))
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
