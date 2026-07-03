from __future__ import annotations

import importlib.util
import json
import os
import posixpath
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

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDragEnterEvent, QDropEvent, QFont, QIcon, QPixmap, QTextCursor
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
    QFrame,
    QHBoxLayout,
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
    return "0.3.0"


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
    if status in {"connecting", "文件处理中", "正在上传", "正在下载", "终端连接中"}:
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

        icon_text = "R" if profile.workspaceKind == "rstudio" else ("J" if profile.workspaceKind == "jupyter" else ">_")
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
        done = QPushButton("完成")
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
        self.add_combo("workspaceKind", "工作区", [("Jupyter", "jupyter"), ("RStudio", "rstudio"), ("终端", "terminal")])
        self.add_line("name", "名称")
        self.add_line("sshPassword", "SSH 密码", password=True)
        self.add_line("jupyterPath", "页面路径")

        self.add_section("网页本地转发")
        self.add_spin("localPort", "本地端口", 1, 65535)
        self.add_line("remoteHost", "远程主机")
        self.add_spin("remotePort", "远程端口", 1, 65535)
        self.add_check("allowRemoteLocalPortAccess", "启用 -g")

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
        preview = QTextEdit()
        preview.setReadOnly(True)
        preview.setFixedHeight(78)
        preview.setPlainText(self.profile.preview_command())
        preview.setStyleSheet("font-family: Consolas, monospace; color: #6b7280;")
        self.form.addWidget(preview)
        self.form.addStretch(1)

    def add_section(self, title: str) -> None:
        label = QLabel(title)
        label.setStyleSheet("font-size: 14px; font-weight: 700; margin-top: 6px;")
        self.form.addWidget(label)

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

    def add_line(self, name: str, label: str, password: bool = False) -> None:
        _, layout = self.row(label)
        field = QLineEdit(str(getattr(self.profile, name)))
        if password:
            field.setEchoMode(QLineEdit.Password)
        layout.addWidget(field, 1)
        self.fields[name] = field

    def add_spin(self, name: str, label: str, low: int, high: int) -> None:
        _, layout = self.row(label)
        field = QSpinBox()
        field.setRange(low, high)
        field.setValue(int(getattr(self.profile, name)))
        field.setMaximumWidth(150)
        layout.addWidget(field)
        layout.addStretch(1)
        self.fields[name] = field

    def add_check(self, name: str, label: str) -> None:
        checkbox = QCheckBox(label)
        checkbox.setChecked(bool(getattr(self.profile, name)))
        self.form.addWidget(checkbox)
        self.fields[name] = checkbox

    def add_combo(self, name: str, label: str, choices: list[tuple[str, str]]) -> None:
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

    def save(self) -> None:
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
        self.saved.emit(SSHProfile.from_dict(values))
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

    def __init__(self) -> None:
        super().__init__()
        self.setAcceptDrops(True)
        self.setDragDropMode(QTreeWidget.DropOnly)

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            super().dragEnterEvent(event)

    def dragMoveEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            super().dragMoveEvent(event)

    def dropEvent(self, event: QDropEvent) -> None:
        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        if paths:
            self.dropped_paths.emit(paths)
            event.acceptProposedAction()
            return
        super().dropEvent(event)


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
        for text, callback in (
            ("Jupyter", lambda: self.add_profile("jupyter")),
            ("RStudio", lambda: self.add_profile("rstudio")),
            ("终端", lambda: self.add_profile("terminal")),
            ("复制", self.duplicate_profile),
            ("删除", self.delete_profile),
            ("设置", self.open_settings),
        ):
            button = QPushButton(text)
            button.clicked.connect(callback)
            bottom.addWidget(button)
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
        add = QToolButton()
        add.setText("+")
        add.setToolTip("新增配置")
        add.clicked.connect(lambda: self.add_profile(kind))
        header.addWidget(add)
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
        self.profile_layout.addStretch(1)

    def is_profile_active(self, profile: SSHProfile) -> bool:
        if profile.is_web_workspace:
            return self.tunnel_profile_id == profile.id and self.tunnel_status in {"connecting", "connected"}
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
        splitter.addWidget(self.file_pane(profile))
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, 1)
        self.detail_layout.addWidget(container, 1)

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
        top.addWidget(StatusPill(self.sftp_status, status_color(self.sftp_status)))
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
        self.file_tree.setHeaderLabels(["名称", "修改时间", "大小", "类型"])
        self.file_tree.setColumnWidth(0, 260)
        self.file_tree.itemDoubleClicked.connect(lambda _item, _column: self.open_selected_remote(profile))
        self.file_tree.dropped_paths.connect(lambda paths: self.upload_paths(profile, paths))
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

    def refresh_files(self, profile: SSHProfile, path: str | None = None) -> None:
        remote_path = (path or self.current_remote_path or ".").strip() or "."
        self.sftp_status = "文件处理中"
        self.bridge.sftp_status.emit(self.sftp_status)

        def work() -> None:
            try:
                entries, actual = self.list_remote_directory(profile, remote_path)
                self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPList", daemon=True).start()

    def list_remote_directory(self, profile: SSHProfile, path: str) -> tuple[list[RemoteFileEntry], str]:
        connection = connect_ssh(profile)
        try:
            sftp = connection.target.open_sftp()
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
        finally:
            connection.close()

    def handle_sftp_done(self, entries: list, actual: str) -> None:
        self.remote_entries = list(entries)
        self.current_remote_path = actual
        self.sftp_status = "文件完成"
        self.render_selected_profile()

    def handle_sftp_error(self, message: str) -> None:
        self.sftp_status = "文件失败"
        QMessageBox.critical(self, APP_NAME, message)
        self.render_selected_profile()

    def handle_sftp_status(self, status: str) -> None:
        self.sftp_status = status
        self.render_selected_profile()

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
            item = QTreeWidgetItem([entry.name, entry.modified, entry.size, entry.kind])
            item.setData(0, Qt.UserRole, entry.path)
            item.setData(0, Qt.UserRole + 1, entry.is_dir)
            tree.addTopLevelItem(item)

    def selected_remote_entry(self) -> RemoteFileEntry | None:
        tree = getattr(self, "file_tree", None)
        if tree is None:
            return None
        items = tree.selectedItems()
        if not items:
            return None
        path = items[0].data(0, Qt.UserRole)
        return next((entry for entry in self.remote_entries if entry.path == path), None)

    def open_selected_remote(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is not None and entry.is_dir:
            self.refresh_files(profile, entry.path)

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
                entries, actual = self.list_remote_directory(profile, remote_dir)
                self.bridge.sftp_done.emit(entries, actual)
            except Exception as exc:
                self.bridge.sftp_error.emit(str(exc))

        threading.Thread(target=work, name="SFTPUpload", daemon=True).start()

    def upload_path(self, profile: SSHProfile, local_path: Path, remote_dir: str) -> None:
        connection = connect_ssh(profile)
        try:
            sftp = connection.target.open_sftp()
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
        finally:
            connection.close()

    def download_selected(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is None:
            QMessageBox.information(self, APP_NAME, "请先选择一个远程文件或文件夹。")
            return
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
        connection = connect_ssh(profile)
        try:
            sftp = connection.target.open_sftp()
            destination = target_dir / entry.name
            if entry.is_dir:
                self.download_dir(sftp, entry.path, destination)
            else:
                sftp.get(entry.path, str(destination))
        finally:
            connection.close()

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
        profile = self.store.add(kind)
        self.refresh_sidebar()
        self.edit_profile(profile)

    def duplicate_profile(self) -> None:
        profile = self.store.duplicate_selected()
        self.refresh_sidebar()
        if profile is not None:
            self.edit_profile(profile)

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

    def edit_profile(self, profile: SSHProfile) -> None:
        dialog = ProfileEditor(profile, self)
        dialog.saved.connect(self.save_profile)
        dialog.exec()

    def save_profile(self, profile: SSHProfile) -> None:
        self.store.update(profile)
        self.store.selected_profile_id = profile.id
        self.refresh_sidebar()
        self.render_selected_profile()

    def closeEvent(self, event) -> None:
        self.disconnect_tunnel(update_ui=False)
        self.disconnect_terminal(update_ui=False)
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
