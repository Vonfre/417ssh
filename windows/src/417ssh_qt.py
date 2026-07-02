from __future__ import annotations

import importlib.util
import os
import posixpath
import stat
import subprocess
import sys
import threading
import time
import webbrowser
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
APP_DIR = Path(__file__).resolve().parents[1]
ASSETS_DIR = APP_DIR / "assets"
CORE_PATH = Path(__file__).with_name("417ssh_windows.py")


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


class Bridge(QObject):
    tunnel_log = Signal(str)
    tunnel_status = Signal(str, object)
    terminal_output = Signal(str)
    terminal_status = Signal(str, object)
    sftp_done = Signal(list, str)
    sftp_error = Signal(str)
    sftp_status = Signal(str)


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
        "background: #e8f6ed; color: #237a4b; border: 1px solid rgba(0,0,0,0.08); border-radius: 8px;"
        "font-weight: 700;"
    )
    return label


def status_color(status: str) -> str:
    if status in {"connected", "文件完成", "终端已连接", "已连接"}:
        return "#1f9d55"
    if status in {"connecting", "文件处理中", "正在上传", "正在下载", "终端连接中"}:
        return "#c77800"
    if status in {"failed", "文件失败", "终端失败", "连接失败"}:
        return "#c93535"
    return "#6b7280"


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

        icon = QLabel("J" if profile.workspaceKind == "jupyter" else ">_")
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
            if profile.workspaceKind == "jupyter"
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
            background = "#e7f0ff"
            border = "#b8cdf8"
        elif active:
            background = "#e9f7ef"
            border = "#b9e5ca"
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
        header.setStyleSheet("background: #f5f7f8; border-radius: 8px;")
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
        self.add_combo("workspaceKind", "工作区", [("Jupyter", "jupyter"), ("终端", "terminal")])
        self.add_line("name", "名称")
        self.add_line("sshPassword", "SSH 密码", password=True)
        self.add_line("jupyterPath", "页面路径")

        self.add_section("Jupyter 本地转发")
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

        self.setWindowTitle(APP_NAME)
        self.resize(1180, 760)
        self.setMinimumSize(980, 640)
        self.install_event_handlers()
        self.build_shell()
        self.refresh_sidebar()
        self.render_selected_profile()

    def install_event_handlers(self) -> None:
        self.bridge.tunnel_log.connect(self.append_tunnel_log)
        self.bridge.tunnel_status.connect(self.handle_tunnel_status)
        self.bridge.terminal_output.connect(self.append_terminal_output)
        self.bridge.terminal_status.connect(self.handle_terminal_status)
        self.bridge.sftp_done.connect(self.handle_sftp_done)
        self.bridge.sftp_error.connect(self.handle_sftp_error)
        self.bridge.sftp_status.connect(self.handle_sftp_status)

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
            ("终端", lambda: self.add_profile("terminal")),
            ("复制", self.duplicate_profile),
            ("删除", self.delete_profile),
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
            QMainWindow { background: #f6f8f8; }
            #Sidebar { background: #f3faf6; }
            QPushButton { padding: 6px 10px; border-radius: 6px; border: 1px solid #c9d2cf; background: #ffffff; }
            QPushButton:hover { background: #f3f7f6; }
            QPushButton[primary="true"] { background: #167044; color: white; border-color: #167044; font-weight: 650; }
            QToolButton { padding: 4px 7px; border-radius: 5px; }
            QToolButton:hover { background: rgba(0,0,0,0.06); }
            QLineEdit, QSpinBox, QComboBox { padding: 6px; border: 1px solid #c9d2cf; border-radius: 6px; background: white; }
            QPlainTextEdit, QTextEdit, QTreeWidget { border: 1px solid #d1d8d6; border-radius: 8px; background: white; }
            QTabWidget::pane { border: 1px solid #d1d8d6; border-radius: 8px; background: white; }
            """
        )

    def section_widget(self, title: str, profiles: list[SSHProfile]) -> QWidget:
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
        kind = "jupyter" if "Jupyter" in title else "terminal"
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
        self.profile_layout.addWidget(self.section_widget("Jupyter 工作区", self.store.profiles_for("jupyter")))
        self.profile_layout.addWidget(self.section_widget("终端工作区", self.store.profiles_for("terminal")))
        self.profile_layout.addStretch(1)

    def is_profile_active(self, profile: SSHProfile) -> bool:
        if profile.workspaceKind == "jupyter":
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
        if profile.workspaceKind == "jupyter":
            self.render_jupyter(profile)
        else:
            self.render_terminal(profile)

    def header(self, profile: SSHProfile, status_text: str, color: str) -> QWidget:
        frame = QFrame()
        frame.setStyleSheet("background: rgba(255,255,255,0.86); border-bottom: 1px solid #d9dfdd;")
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
        detail = QLabel(profile.local_url if profile.workspaceKind == "jupyter" else (profile.target_address or "未填写目标主机"))
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

    def render_jupyter(self, profile: SSHProfile) -> None:
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
        tabs_label = StatusPill("Jupyter 已连接" if self.is_profile_active(profile) else "Jupyter 未连接", "#1f9d55" if self.is_profile_active(profile) else "#6b7280")
        controls.addWidget(tabs_label)
        controls.addStretch(1)
        config = QPushButton("配置")
        config.clicked.connect(lambda: self.edit_profile(profile))
        controls.addWidget(config)
        reload_button = QPushButton("刷新")
        reload_button.clicked.connect(lambda: self.load_jupyter_url(profile))
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
            self.load_jupyter_url(profile)
        elif QWebEngineView is not None:
            placeholder = QLabel("连接成功后，这里会显示 Jupyter Lab")
            placeholder.setAlignment(Qt.AlignCenter)
            placeholder.setStyleSheet("color: #6b7280; background: white; border-radius: 8px;")
            browser_layout.addWidget(placeholder, 1)
        else:
            fallback = QFrame()
            fallback_layout = QVBoxLayout(fallback)
            fallback_layout.setAlignment(Qt.AlignCenter)
            message = QLabel("未安装 Qt WebEngine，Jupyter 将使用系统默认浏览器打开。")
            message.setStyleSheet("color: #6b7280;")
            open_button = QPushButton("打开浏览器")
            open_button.clicked.connect(lambda: webbrowser.open(profile.local_url))
            fallback_layout.addWidget(message)
            fallback_layout.addWidget(open_button, 0, Qt.AlignCenter)
            browser_layout.addWidget(fallback, 1)
        tabs.addTab(browser, "Jupyter")

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
                    QTimer.singleShot(100, lambda: self.load_jupyter_url(active))
        if status == "failed":
            self.tunnel_profile_id = None
        self.refresh_sidebar()
        self.render_selected_profile()

    def load_jupyter_url(self, profile: SSHProfile) -> None:
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
