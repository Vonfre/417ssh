from __future__ import annotations

import json
import os
import posixpath
import queue
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
import webbrowser
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

try:
    import paramiko
except ImportError:  # pragma: no cover - handled in the UI at runtime
    paramiko = None

try:
    from PIL import Image, ImageTk
except ImportError:  # pragma: no cover - logo is optional
    Image = None
    ImageTk = None


APP_NAME = "417ssh"
APP_DIR = Path(__file__).resolve().parents[1]
ASSETS_DIR = APP_DIR / "assets"


def config_dir() -> Path:
    root = os.environ.get("APPDATA")
    if root:
        return Path(root) / APP_NAME
    return Path.home() / ".417ssh"


CONFIG_DIR = config_dir()
PROFILES_FILE = CONFIG_DIR / "profiles.json"
WEB_WORKSPACE_KINDS = {"jupyter", "rstudio"}


def workspace_title(kind: str) -> str:
    if kind == "rstudio":
        return "RStudio"
    if kind == "terminal":
        return "终端"
    if kind == "sftp":
        return "SFTP"
    return "Jupyter"


def default_profile_name(kind: str, number: int) -> str:
    title = workspace_title(kind)
    if kind == "terminal":
        return "新终端" if number <= 1 else f"新终端 {number}"
    if kind == "sftp":
        return "新 SFTP" if number <= 1 else f"新 SFTP {number}"
    return f"新 {title}" if number <= 1 else f"新 {title} {number}"


def default_local_port(kind: str, number: int) -> int:
    if kind == "rstudio":
        return 8008 + max(0, number - 1)
    return 8000 + max(0, number - 1)


def default_remote_host(kind: str) -> str:
    return "localhost" if kind == "rstudio" else "127.0.0.1"


def default_remote_port(kind: str) -> int:
    return 8787 if kind == "rstudio" else 8888


def default_http_path(kind: str) -> str:
    return "/" if kind == "rstudio" else "/lab/tree/work"


def normalized_http_path(value: str) -> str:
    text = value.strip()
    if not text:
        return "/"
    return text if text.startswith("/") else "/" + text


def clamp_int(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def bytes_label(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def safe_int(value: str, fallback: int) -> int:
    try:
        return int(str(value).strip())
    except ValueError:
        return fallback


@dataclass
class SSHProfile:
    id: str
    workspaceKind: str
    name: str
    localPort: int
    remoteHost: str
    remotePort: int
    jumpUser: str
    jumpHost: str
    jumpPort: int
    targetUser: str
    targetHost: str
    targetPort: int
    jupyterPath: str
    sshPassword: str
    identityFile: str
    compressionEnabled: bool
    verboseLogging: bool
    allowRemoteLocalPortAccess: bool
    keepAliveEnabled: bool
    keepAliveInterval: int
    keepAliveCountMax: int
    useSSHConfig: bool

    @classmethod
    def sample(cls) -> "SSHProfile":
        return cls.blank(1, "jupyter")

    @classmethod
    def blank(cls, number: int, kind: str) -> "SSHProfile":
        return cls(
            id=str(uuid.uuid4()),
            workspaceKind=kind,
            name=default_profile_name(kind, number),
            localPort=default_local_port(kind, number),
            remoteHost=default_remote_host(kind),
            remotePort=default_remote_port(kind),
            jumpUser="",
            jumpHost="",
            jumpPort=22,
            targetUser="",
            targetHost="",
            targetPort=22,
            jupyterPath=default_http_path(kind),
            sshPassword="",
            identityFile="",
            compressionEnabled=True,
            verboseLogging=False,
            allowRemoteLocalPortAccess=False,
            keepAliveEnabled=True,
            keepAliveInterval=30,
            keepAliveCountMax=120,
            useSSHConfig=False,
        )

    @classmethod
    def from_dict(cls, data: dict) -> "SSHProfile":
        kind = str(data.get("workspaceKind") or "jupyter")
        defaults = asdict(cls.blank(1, kind))
        defaults.update({key: value for key, value in data.items() if key in defaults})
        if not defaults.get("id"):
            defaults["id"] = str(uuid.uuid4())
        return cls(**defaults)

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def is_web_workspace(self) -> bool:
        return self.workspaceKind in WEB_WORKSPACE_KINDS

    @property
    def workspace_title(self) -> str:
        return workspace_title(self.workspaceKind)

    @property
    def target_address(self) -> str:
        user = self.targetUser.strip()
        host = self.targetHost.strip()
        return f"{user}@{host}" if user else host

    @property
    def jump_address(self) -> str:
        user = self.jumpUser.strip()
        host = self.jumpHost.strip()
        host_part = f"{user}@{host}" if user else host
        return f"{host_part}:{self.jumpPort}"

    @property
    def has_jump_host(self) -> bool:
        return bool(self.jumpHost.strip())

    @property
    def forward_spec(self) -> str:
        return f"{self.localPort}:{self.remoteHost}:{self.remotePort}"

    @property
    def local_url(self) -> str:
        return f"http://127.0.0.1:{self.localPort}{normalized_http_path(self.jupyterPath)}"

    def keep_alive_args(self) -> list[str]:
        if not self.keepAliveEnabled:
            return []
        interval = clamp_int(self.keepAliveInterval, 10, 600)
        count_max = clamp_int(self.keepAliveCountMax, 3, 720)
        return [
            "-o",
            f"ServerAliveInterval={interval}",
            "-o",
            f"ServerAliveCountMax={count_max}",
            "-o",
            "TCPKeepAlive=yes",
        ]

    def ssh_config_args(self) -> list[str]:
        return [] if self.useSSHConfig else ["-F", "none"]

    def tunnel_ssh_args(self, include_batch_mode: bool = False) -> list[str]:
        args: list[str] = []
        if self.compressionEnabled:
            args.append("-C")
        args.extend(self.ssh_config_args())
        args.append("-N")
        if self.allowRemoteLocalPortAccess:
            args.append("-g")
        if self.verboseLogging:
            args.append("-v")
        if include_batch_mode:
            args.extend(["-o", "BatchMode=yes"])
        args.extend(self.keep_alive_args())
        args.extend(["-o", "ExitOnForwardFailure=yes"])
        if self.identityFile.strip():
            args.extend(["-i", os.path.expanduser(self.identityFile.strip())])
        if self.targetPort != 22:
            args.extend(["-p", str(self.targetPort)])
        args.extend(["-L", self.forward_spec])
        if self.has_jump_host:
            args.extend(["-J", self.jump_address])
        args.append(self.target_address)
        return args

    def terminal_ssh_args(self, include_batch_mode: bool = False) -> list[str]:
        args: list[str] = []
        if self.compressionEnabled:
            args.append("-C")
        args.extend(self.ssh_config_args())
        args.append("-tt")
        if include_batch_mode:
            args.extend(["-o", "BatchMode=yes"])
        args.extend(self.keep_alive_args())
        if self.identityFile.strip():
            args.extend(["-i", os.path.expanduser(self.identityFile.strip())])
        if self.targetPort != 22:
            args.extend(["-p", str(self.targetPort)])
        if self.has_jump_host:
            args.extend(["-J", self.jump_address])
        args.append(self.target_address)
        return args

    def preview_command(self) -> str:
        args = self.tunnel_ssh_args(False) if self.is_web_workspace else self.terminal_ssh_args(False)
        return subprocess.list2cmdline(["ssh"] + args)


@dataclass
class RemoteFileEntry:
    name: str
    path: str
    is_dir: bool
    is_link: bool
    permissions: str
    size: str
    modified: str

    @property
    def kind(self) -> str:
        if self.is_dir:
            return "文件夹"
        if self.is_link:
            return "链接"
        return "文件"


class ProfileStore:
    def __init__(self) -> None:
        self.profiles: list[SSHProfile] = self.load()
        self.selected_profile_id = self.profiles[0].id if self.profiles else None

    def load(self) -> list[SSHProfile]:
        if not PROFILES_FILE.exists():
            return [SSHProfile.sample()]
        try:
            data = json.loads(PROFILES_FILE.read_text(encoding="utf-8"))
            profiles = [SSHProfile.from_dict(item) for item in data if isinstance(item, dict)]
            return profiles or [SSHProfile.sample()]
        except Exception:
            return [SSHProfile.sample()]

    def save(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = [profile.to_dict() for profile in self.profiles]
        PROFILES_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def profiles_for(self, kind: str) -> list[SSHProfile]:
        return [profile for profile in self.profiles if profile.workspaceKind == kind]

    def selected(self) -> SSHProfile | None:
        for profile in self.profiles:
            if profile.id == self.selected_profile_id:
                return profile
        return self.profiles[0] if self.profiles else None

    def add(self, kind: str) -> SSHProfile:
        count = len(self.profiles_for(kind))
        profile = SSHProfile.blank(count + 1, kind)
        profile.name = self.next_name(profile.name)
        self.profiles.append(profile)
        self.selected_profile_id = profile.id
        self.save()
        return profile

    def duplicate_selected(self) -> SSHProfile | None:
        profile = self.selected()
        if profile is None:
            return None
        clone = SSHProfile.from_dict(profile.to_dict())
        clone.id = str(uuid.uuid4())
        clone.name = self.next_name(f"{profile.name} 副本")
        self.profiles.append(clone)
        self.selected_profile_id = clone.id
        self.save()
        return clone

    def delete_selected(self) -> None:
        selected = self.selected_profile_id
        self.profiles = [profile for profile in self.profiles if profile.id != selected]
        if not self.profiles:
            self.profiles = [SSHProfile.sample()]
        self.selected_profile_id = self.profiles[0].id
        self.save()

    def update(self, updated: SSHProfile) -> None:
        for index, profile in enumerate(self.profiles):
            if profile.id == updated.id:
                self.profiles[index] = updated
                self.save()
                return

    def next_name(self, base: str) -> str:
        names = {profile.name for profile in self.profiles}
        candidate = base
        suffix = 2
        while candidate in names:
            candidate = f"{base} {suffix}"
            suffix += 1
        return candidate


class SSHConnection:
    def __init__(self, target, jump=None) -> None:
        self.target = target
        self.jump = jump

    def close(self) -> None:
        for client in (self.target, self.jump):
            if client is not None:
                try:
                    client.close()
                except Exception:
                    pass


def require_paramiko() -> None:
    if paramiko is None:
        raise RuntimeError("缺少 Paramiko。请在 windows 目录运行：python -m pip install -r requirements.txt")


def new_ssh_client():
    require_paramiko()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    return client


def load_ssh_config() -> object | None:
    if paramiko is None:
        return None
    config_path = Path.home() / ".ssh" / "config"
    if not config_path.exists():
        return None
    config = paramiko.SSHConfig()
    with config_path.open("r", encoding="utf-8", errors="ignore") as handle:
        config.parse(handle)
    return config


def endpoint_from_profile(profile: SSHProfile, host: str, user: str, port: int) -> tuple[str, str, int, str]:
    identity_file = profile.identityFile.strip()
    if profile.useSSHConfig:
        config = load_ssh_config()
        if config is not None and host:
            lookup = config.lookup(host)
            host = lookup.get("hostname", host)
            user = user or lookup.get("user", "")
            if lookup.get("port"):
                port = safe_int(str(lookup["port"]), port)
            identity = lookup.get("identityfile")
            if not identity_file and identity:
                identity_file = identity[0] if isinstance(identity, list) else str(identity)
    return host.strip(), user.strip(), port, os.path.expanduser(identity_file) if identity_file else ""


def connect_ssh(profile: SSHProfile, log: Callable[[str], None] | None = None) -> SSHConnection:
    require_paramiko()
    if not profile.targetHost.strip():
        raise RuntimeError("目标主机为空，请先在配置里填写目标主机。")

    def emit(message: str) -> None:
        if log is not None:
            log(message)

    password = profile.sshPassword or None
    target_host, target_user, target_port, identity_file = endpoint_from_profile(
        profile, profile.targetHost, profile.targetUser, profile.targetPort
    )
    key_filename = identity_file or None
    connect_options = {
        "username": target_user or None,
        "password": password,
        "key_filename": key_filename,
        "look_for_keys": key_filename is None,
        "allow_agent": True,
        "timeout": 18,
        "banner_timeout": 18,
        "auth_timeout": 18,
        "compress": profile.compressionEnabled,
    }

    jump_client = None
    sock = None
    if profile.has_jump_host:
        jump_host, jump_user, jump_port, jump_identity_file = endpoint_from_profile(
            profile, profile.jumpHost, profile.jumpUser, profile.jumpPort
        )
        emit(f"连接跳板机：{jump_user + '@' if jump_user else ''}{jump_host}:{jump_port}")
        jump_client = new_ssh_client()
        jump_client.connect(
            hostname=jump_host,
            port=jump_port,
            username=jump_user or None,
            password=password,
            key_filename=jump_identity_file or key_filename,
            look_for_keys=(jump_identity_file or key_filename) is None,
            allow_agent=True,
            timeout=18,
            banner_timeout=18,
            auth_timeout=18,
            compress=profile.compressionEnabled,
        )
        transport = jump_client.get_transport()
        if transport is None:
            raise RuntimeError("跳板机连接没有可用 transport。")
        emit(f"通过跳板机连接目标：{target_user + '@' if target_user else ''}{target_host}:{target_port}")
        sock = transport.open_channel(
            "direct-tcpip",
            (target_host, target_port),
            ("127.0.0.1", 0),
        )
    else:
        emit(f"连接目标：{target_user + '@' if target_user else ''}{target_host}:{target_port}")

    target_client = new_ssh_client()
    try:
        target_client.connect(hostname=target_host, port=target_port, sock=sock, **connect_options)
    except Exception:
        if jump_client is not None:
            jump_client.close()
        raise

    return SSHConnection(target=target_client, jump=jump_client)


class TunnelServer:
    def __init__(
        self,
        profile: SSHProfile,
        log: Callable[[str], None],
        status: Callable[[str, str | None], None],
    ) -> None:
        self.profile = profile
        self.log = log
        self.status = status
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.listener: socket.socket | None = None
        self.connection: SSHConnection | None = None
        self.client_sockets: list[socket.socket] = []
        self.channels: list[object] = []

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self.run, name="WebTunnel", daemon=True)
        self.thread.start()

    def run(self) -> None:
        bind_host = "0.0.0.0" if self.profile.allowRemoteLocalPortAccess else "127.0.0.1"
        try:
            self.status("connecting", None)
            self.log(f"开始建立隧道：{self.profile.name}")
            self.log(f"本地地址：{self.profile.local_url}")
            self.log(f"转发规则：{self.profile.localPort} -> {self.profile.remoteHost}:{self.profile.remotePort}")

            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((bind_host, self.profile.localPort))
            listener.listen(64)
            listener.settimeout(0.5)
            self.listener = listener

            self.connection = connect_ssh(self.profile, self.log)
            self.status("connected", None)
            self.log("隧道已连接，等待本地浏览器访问。")

            while not self.stop_event.is_set():
                try:
                    client_sock, address = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                self.client_sockets.append(client_sock)
                self.log(f"本地连接进入：{address[0]}:{address[1]}")
                worker = threading.Thread(
                    target=self.forward_client,
                    args=(client_sock,),
                    name="TunnelForward",
                    daemon=True,
                )
                worker.start()
        except OSError as exc:
            if exc.errno in (48, 98, 10048):
                message = f"本地端口 {self.profile.localPort} 已被占用。"
            else:
                message = str(exc)
            self.log(message)
            self.status("failed", message)
        except Exception as exc:
            message = str(exc)
            self.log(f"隧道连接失败：{message}")
            self.status("failed", message)
        finally:
            self.close_resources()

    def forward_client(self, client_sock: socket.socket) -> None:
        channel = None
        close_once = threading.Event()

        def close_pair() -> None:
            if close_once.is_set():
                return
            close_once.set()
            try:
                client_sock.close()
            except Exception:
                pass
            if channel is not None:
                try:
                    channel.close()
                except Exception:
                    pass

        def copy_socket_to_channel() -> None:
            try:
                while not self.stop_event.is_set():
                    data = client_sock.recv(32768)
                    if not data:
                        break
                    channel.sendall(data)
            except Exception:
                pass
            finally:
                close_pair()

        def copy_channel_to_socket() -> None:
            try:
                while not self.stop_event.is_set():
                    data = channel.recv(32768)
                    if not data:
                        break
                    client_sock.sendall(data)
            except Exception:
                pass
            finally:
                close_pair()

        try:
            if self.connection is None:
                raise RuntimeError("SSH 连接尚未建立。")
            transport = self.connection.target.get_transport()
            if transport is None:
                raise RuntimeError("目标 SSH transport 不可用。")
            channel = transport.open_channel(
                "direct-tcpip",
                (self.profile.remoteHost, self.profile.remotePort),
                client_sock.getpeername(),
            )
            self.channels.append(channel)
            threading.Thread(target=copy_socket_to_channel, name="TunnelUp", daemon=True).start()
            threading.Thread(target=copy_channel_to_socket, name="TunnelDown", daemon=True).start()
        except Exception as exc:
            self.log(f"转发连接失败：{exc}")
            close_pair()

    def stop(self) -> None:
        self.stop_event.set()
        self.close_resources()
        self.status("disconnected", None)

    def close_resources(self) -> None:
        if self.listener is not None:
            try:
                self.listener.close()
            except Exception:
                pass
            self.listener = None
        for client_sock in list(self.client_sockets):
            try:
                client_sock.close()
            except Exception:
                pass
        self.client_sockets.clear()
        for channel in list(self.channels):
            try:
                channel.close()
            except Exception:
                pass
        self.channels.clear()
        if self.connection is not None:
            self.connection.close()
            self.connection = None


class TerminalSession:
    def __init__(
        self,
        profile: SSHProfile,
        output: Callable[[str], None],
        status: Callable[[str, str | None], None],
    ) -> None:
        self.profile = profile
        self.output = output
        self.status = status
        self.stop_event = threading.Event()
        self.connection: SSHConnection | None = None
        self.channel = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.thread = threading.Thread(target=self.run, name="TerminalSession", daemon=True)
        self.thread.start()

    def run(self) -> None:
        try:
            self.status("connecting", None)
            self.output(f"正在连接 {self.profile.target_address} ...\n")
            self.connection = connect_ssh(self.profile, lambda text: self.output(text + "\n"))
            transport = self.connection.target.get_transport()
            if transport is None:
                raise RuntimeError("目标 SSH transport 不可用。")
            self.channel = transport.open_session()
            self.channel.get_pty(term="xterm", width=120, height=32)
            self.channel.invoke_shell()
            self.status("connected", None)
            while not self.stop_event.is_set():
                if self.channel.recv_ready():
                    data = self.channel.recv(4096)
                    if not data:
                        break
                    self.output(data.decode("utf-8", errors="replace"))
                elif self.channel.exit_status_ready():
                    break
                else:
                    time.sleep(0.04)
            self.status("disconnected", None)
        except Exception as exc:
            self.output(f"\n终端连接失败：{exc}\n")
            self.status("failed", str(exc))
        finally:
            self.close()

    def send(self, text: str) -> None:
        if self.channel is None:
            return
        try:
            self.channel.send(text)
        except Exception as exc:
            self.output(f"\n发送失败：{exc}\n")

    def close(self) -> None:
        self.stop_event.set()
        if self.channel is not None:
            try:
                self.channel.close()
            except Exception:
                pass
            self.channel = None
        if self.connection is not None:
            self.connection.close()
            self.connection = None


class ProfileEditor(tk.Toplevel):
    def __init__(self, master: "App", profile: SSHProfile, on_save: Callable[[SSHProfile], None]) -> None:
        super().__init__(master)
        self.title("修改配置")
        self.geometry("620x720")
        self.minsize(560, 620)
        self.profile = SSHProfile.from_dict(profile.to_dict())
        self.on_save = on_save
        self.vars: dict[str, tk.Variable] = {}
        self.create_widgets()
        self.transient(master)
        self.grab_set()

    def create_widgets(self) -> None:
        container = ttk.Frame(self, padding=12)
        container.pack(fill=tk.BOTH, expand=True)

        header = ttk.Frame(container)
        header.pack(fill=tk.X, pady=(0, 10))
        ttk.Label(header, text="修改配置", font=("Microsoft YaHei UI", 14, "bold")).pack(side=tk.LEFT)
        ttk.Button(header, text="完成", command=self.save).pack(side=tk.RIGHT)

        canvas = tk.Canvas(container, highlightthickness=0)
        scrollbar = ttk.Scrollbar(container, orient=tk.VERTICAL, command=canvas.yview)
        self.form = ttk.Frame(canvas)
        self.form.bind("<Configure>", lambda _event: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=self.form, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.section("基本配置")
        self.choice("workspaceKind", "工作区", [("Jupyter", "jupyter"), ("RStudio", "rstudio"), ("终端", "terminal"), ("SFTP", "sftp")])
        self.text("name", "名称")
        self.password("sshPassword", "SSH 密码")
        self.text("jupyterPath", "页面路径")

        self.section("网页本地转发")
        self.integer("localPort", "本地端口")
        self.text("remoteHost", "远程主机")
        self.integer("remotePort", "远程端口")
        self.boolean("allowRemoteLocalPortAccess", "启用 -g")

        self.section("跳板机")
        self.text("jumpUser", "用户名")
        self.text("jumpHost", "主机")
        self.integer("jumpPort", "端口")

        self.section("目标主机")
        self.text("targetUser", "用户名")
        self.text("targetHost", "主机")
        self.integer("targetPort", "SSH 端口")
        self.text("identityFile", "密钥文件")
        self.boolean("compressionEnabled", "启用压缩 (-C)")
        self.boolean("verboseLogging", "详细日志 (-v)")

        self.section("连接稳定性")
        self.boolean("keepAliveEnabled", "保持长连接")
        self.integer("keepAliveInterval", "保活间隔")
        self.integer("keepAliveCountMax", "容错次数")
        self.boolean("useSSHConfig", "读取 ~/.ssh/config")

        self.section("命令预览")
        preview = tk.Text(self.form, height=4, wrap=tk.WORD)
        preview.insert("1.0", self.profile.preview_command())
        preview.configure(state=tk.DISABLED)
        preview.pack(fill=tk.X, padx=6, pady=(0, 10))

    def section(self, title: str) -> None:
        ttk.Label(self.form, text=title, font=("Microsoft YaHei UI", 10, "bold")).pack(
            fill=tk.X, padx=6, pady=(14, 6)
        )

    def row(self, label: str) -> ttk.Frame:
        frame = ttk.Frame(self.form)
        frame.pack(fill=tk.X, padx=6, pady=4)
        ttk.Label(frame, text=label, width=12).pack(side=tk.LEFT)
        return frame

    def text(self, name: str, label: str) -> None:
        frame = self.row(label)
        var = tk.StringVar(value=str(getattr(self.profile, name)))
        self.vars[name] = var
        ttk.Entry(frame, textvariable=var).pack(side=tk.LEFT, fill=tk.X, expand=True)

    def password(self, name: str, label: str) -> None:
        frame = self.row(label)
        var = tk.StringVar(value=str(getattr(self.profile, name)))
        self.vars[name] = var
        ttk.Entry(frame, textvariable=var, show="*").pack(side=tk.LEFT, fill=tk.X, expand=True)

    def integer(self, name: str, label: str) -> None:
        frame = self.row(label)
        var = tk.StringVar(value=str(getattr(self.profile, name)))
        self.vars[name] = var
        ttk.Entry(frame, textvariable=var, width=12).pack(side=tk.LEFT)

    def boolean(self, name: str, label: str) -> None:
        frame = ttk.Frame(self.form)
        frame.pack(fill=tk.X, padx=6, pady=4)
        var = tk.BooleanVar(value=bool(getattr(self.profile, name)))
        self.vars[name] = var
        ttk.Checkbutton(frame, text=label, variable=var).pack(side=tk.LEFT)

    def choice(self, name: str, label: str, choices: list[tuple[str, str]]) -> None:
        frame = self.row(label)
        var = tk.StringVar(value=str(getattr(self.profile, name)))
        self.vars[name] = var
        combo = ttk.Combobox(frame, textvariable=var, values=[value for _, value in choices], state="readonly")
        combo.pack(side=tk.LEFT, fill=tk.X, expand=True)

    def save(self) -> None:
        values = self.profile.to_dict()
        for name, var in self.vars.items():
            old_value = values.get(name)
            if isinstance(old_value, bool):
                values[name] = bool(var.get())
            elif isinstance(old_value, int):
                values[name] = safe_int(str(var.get()), old_value)
            else:
                values[name] = str(var.get())
        updated = SSHProfile.from_dict(values)
        self.on_save(updated)
        self.destroy()


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_NAME)
        self.geometry("1180x760")
        self.minsize(980, 640)
        self.ui_queue: queue.Queue[Callable[[], None]] = queue.Queue()
        self.store = ProfileStore()
        self.tunnel: TunnelServer | None = None
        self.tunnel_profile_id: str | None = None
        self.tunnel_status = "disconnected"
        self.tunnel_message: str | None = None
        self.terminal: TerminalSession | None = None
        self.terminal_profile_id: str | None = None
        self.terminal_status = "disconnected"
        self.sftp_status = "文件空闲"
        self.remote_entries: list[RemoteFileEntry] = []
        self.current_remote_path = "."
        self.logo_image = self.load_logo()
        self.configure_styles()
        self.create_widgets()
        self.refresh_sidebar()
        self.render_selected_profile()
        self.after(80, self.drain_ui_queue)
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    def load_logo(self):
        logo = ASSETS_DIR / "logo.jpg"
        if Image is None or ImageTk is None or not logo.exists():
            return None
        try:
            image = Image.open(logo).resize((38, 38))
            return ImageTk.PhotoImage(image)
        except Exception:
            return None

    def configure_styles(self) -> None:
        style = ttk.Style(self)
        if sys.platform == "win32":
            style.theme_use("vista")
        style.configure("Sidebar.TFrame", background="#f3faf6")
        style.configure("Header.TLabel", font=("Microsoft YaHei UI", 12, "bold"))
        style.configure("Muted.TLabel", foreground="#69736f")
        style.configure("Status.TLabel", font=("Microsoft YaHei UI", 9, "bold"))
        style.configure("Primary.TButton", font=("Microsoft YaHei UI", 9, "bold"))

    def create_widgets(self) -> None:
        root = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        root.pack(fill=tk.BOTH, expand=True)

        self.sidebar = ttk.Frame(root, width=270, style="Sidebar.TFrame")
        self.content = ttk.Frame(root)
        root.add(self.sidebar, weight=0)
        root.add(self.content, weight=1)

        header = ttk.Frame(self.sidebar, padding=(12, 12, 12, 8), style="Sidebar.TFrame")
        header.pack(fill=tk.X)
        if self.logo_image is not None:
            ttk.Label(header, image=self.logo_image, background="#f3faf6").pack(side=tk.LEFT, padx=(0, 10))
        title_box = ttk.Frame(header, style="Sidebar.TFrame")
        title_box.pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Label(title_box, text=APP_NAME, style="Header.TLabel", background="#f3faf6").pack(anchor=tk.W)
        ttk.Label(title_box, text="连接 / 终端 / 文件", style="Muted.TLabel", background="#f3faf6").pack(anchor=tk.W)

        self.profile_tree = ttk.Treeview(self.sidebar, show="tree", selectmode="browse")
        self.profile_tree.pack(fill=tk.BOTH, expand=True, padx=10, pady=6)
        self.profile_tree.bind("<<TreeviewSelect>>", self.on_profile_select)

        controls = ttk.Frame(self.sidebar, padding=10, style="Sidebar.TFrame")
        controls.pack(fill=tk.X)
        ttk.Button(controls, text="+ Jupyter", command=lambda: self.add_profile("jupyter")).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4)
        )
        ttk.Button(controls, text="+ RStudio", command=lambda: self.add_profile("rstudio")).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=4
        )
        ttk.Button(controls, text="+ 终端", command=lambda: self.add_profile("terminal")).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=4
        )
        ttk.Button(controls, text="复制", command=self.duplicate_profile).pack(side=tk.LEFT, padx=4)
        ttk.Button(controls, text="删除", command=self.delete_profile).pack(side=tk.LEFT, padx=(4, 0))

    def post(self, callback: Callable[[], None]) -> None:
        self.ui_queue.put(callback)

    def drain_ui_queue(self) -> None:
        while True:
            try:
                callback = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                callback()
            except Exception as exc:
                print(exc, file=sys.stderr)
        self.after(80, self.drain_ui_queue)

    def refresh_sidebar(self) -> None:
        selected = self.store.selected_profile_id
        self.profile_tree.delete(*self.profile_tree.get_children())
        for kind, title in (("jupyter", "Jupyter 工作区"), ("rstudio", "RStudio 工作区"), ("terminal", "终端工作区"), ("sftp", "SFTP 工作区")):
            parent = f"group:{kind}"
            self.profile_tree.insert("", tk.END, iid=parent, text=title, open=True)
            for profile in self.store.profiles_for(kind):
                marker = "  ● " if self.is_profile_active(profile) else "    "
                self.profile_tree.insert(parent, tk.END, iid=profile.id, text=marker + profile.name)
        if selected:
            try:
                self.profile_tree.selection_set(selected)
                self.profile_tree.see(selected)
            except tk.TclError:
                pass

    def is_profile_active(self, profile: SSHProfile) -> bool:
        if profile.is_web_workspace:
            return self.tunnel_profile_id == profile.id and self.tunnel_status in {"connecting", "connected"}
        return self.terminal_profile_id == profile.id and self.terminal_status in {"connecting", "connected"}

    def on_profile_select(self, _event=None) -> None:
        selected = self.profile_tree.selection()
        if not selected:
            return
        item = selected[0]
        if item.startswith("group:"):
            return
        self.store.selected_profile_id = item
        self.render_selected_profile()

    def clear_content(self) -> None:
        for child in self.content.winfo_children():
            child.destroy()

    def render_selected_profile(self) -> None:
        self.clear_content()
        profile = self.store.selected()
        if profile is None:
            ttk.Label(self.content, text="未选择配置").pack(expand=True)
            return
        if profile.is_web_workspace:
            self.render_web_workspace(profile)
        else:
            self.render_terminal(profile)

    def make_header(self, profile: SSHProfile, parent: ttk.Frame, status_text: str) -> ttk.Frame:
        header = ttk.Frame(parent, padding=(12, 10))
        header.pack(fill=tk.X)
        if self.logo_image is not None:
            ttk.Label(header, image=self.logo_image).pack(side=tk.LEFT, padx=(0, 10))
        labels = ttk.Frame(header)
        labels.pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Label(labels, text=profile.name, style="Header.TLabel").pack(anchor=tk.W)
        detail = profile.local_url if profile.is_web_workspace else (profile.target_address or "未填写目标主机")
        ttk.Label(labels, text=detail, style="Muted.TLabel").pack(anchor=tk.W)
        ttk.Label(header, text=status_text, style="Status.TLabel").pack(side=tk.RIGHT, padx=(10, 0))
        return header

    def render_web_workspace(self, profile: SSHProfile) -> None:
        status_text = {
            "disconnected": "未连接",
            "connecting": "连接中",
            "connected": "已连接",
            "failed": "连接失败",
        }.get(self.tunnel_status, "未连接")
        self.make_header(profile, self.content, status_text)

        controls = ttk.Frame(self.content, padding=(12, 0, 12, 10))
        controls.pack(fill=tk.X)
        ttk.Button(controls, text="配置", command=lambda: self.edit_profile(profile)).pack(side=tk.LEFT)
        ttk.Button(controls, text="打开浏览器", command=lambda: webbrowser.open(profile.local_url)).pack(
            side=tk.LEFT, padx=6
        )
        ttk.Button(controls, text="清空日志", command=self.clear_tunnel_log).pack(side=tk.LEFT, padx=6)
        if self.tunnel_profile_id == profile.id and self.tunnel_status in {"connecting", "connected"}:
            ttk.Button(controls, text="断开", command=self.disconnect_tunnel, style="Primary.TButton").pack(
                side=tk.RIGHT
            )
        else:
            ttk.Button(controls, text="连接", command=lambda: self.connect_tunnel(profile), style="Primary.TButton").pack(
                side=tk.RIGHT
            )

        body = ttk.Notebook(self.content)
        body.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 12))

        browser_frame = ttk.Frame(body, padding=18)
        body.add(browser_frame, text=profile.workspace_title)
        ttk.Label(browser_frame, text=f"{profile.workspace_title} 地址", font=("Microsoft YaHei UI", 11, "bold")).pack(anchor=tk.W)
        url_entry = ttk.Entry(browser_frame)
        url_entry.insert(0, profile.local_url)
        url_entry.configure(state="readonly")
        url_entry.pack(fill=tk.X, pady=(8, 12))
        ttk.Button(browser_frame, text="在默认浏览器打开", command=lambda: webbrowser.open(profile.local_url)).pack(
            anchor=tk.W
        )
        ttk.Label(
            browser_frame,
            text=f"Windows 版使用系统默认浏览器显示 {profile.workspace_title}；隧道由本应用保持。",
            style="Muted.TLabel",
        ).pack(anchor=tk.W, pady=(14, 0))

        log_frame = ttk.Frame(body)
        body.add(log_frame, text="日志")
        self.tunnel_log = tk.Text(log_frame, wrap=tk.WORD)
        self.tunnel_log.pack(fill=tk.BOTH, expand=True)
        self.tunnel_log.insert("1.0", getattr(self, "_tunnel_log_text", "暂无日志。\n"))
        self.tunnel_log.configure(state=tk.DISABLED)

    def append_tunnel_log(self, text: str) -> None:
        def apply() -> None:
            current = getattr(self, "_tunnel_log_text", "")
            self._tunnel_log_text = (current + text.rstrip() + "\n")[-80000:]
            if hasattr(self, "tunnel_log") and self.tunnel_log.winfo_exists():
                self.tunnel_log.configure(state=tk.NORMAL)
                self.tunnel_log.delete("1.0", tk.END)
                self.tunnel_log.insert("1.0", self._tunnel_log_text)
                self.tunnel_log.see(tk.END)
                self.tunnel_log.configure(state=tk.DISABLED)

        self.post(apply)

    def clear_tunnel_log(self) -> None:
        self._tunnel_log_text = ""
        if hasattr(self, "tunnel_log") and self.tunnel_log.winfo_exists():
            self.tunnel_log.configure(state=tk.NORMAL)
            self.tunnel_log.delete("1.0", tk.END)
            self.tunnel_log.configure(state=tk.DISABLED)

    def connect_tunnel(self, profile: SSHProfile) -> None:
        self.disconnect_tunnel()
        self.tunnel_profile_id = profile.id
        self.tunnel_status = "connecting"
        self.tunnel_message = None
        self._tunnel_log_text = ""
        self.tunnel = TunnelServer(profile, self.append_tunnel_log, self.on_tunnel_status)
        self.tunnel.start()
        self.refresh_sidebar()
        self.render_selected_profile()

    def disconnect_tunnel(self) -> None:
        if self.tunnel is not None:
            self.tunnel.stop()
            self.tunnel = None
        self.tunnel_status = "disconnected"
        self.tunnel_profile_id = None
        self.refresh_sidebar()

    def on_tunnel_status(self, status: str, message: str | None) -> None:
        def apply() -> None:
            old_status = self.tunnel_status
            self.tunnel_status = status
            self.tunnel_message = message
            if status == "connected" and old_status != "connected":
                profile = self.store.selected()
                active = next((item for item in self.store.profiles if item.id == self.tunnel_profile_id), profile)
                if active is not None:
                    webbrowser.open(active.local_url)
            if status in {"failed", "disconnected"} and status != "disconnected":
                self.tunnel_profile_id = None
            self.refresh_sidebar()
            self.render_selected_profile()

        self.post(apply)

    def render_terminal(self, profile: SSHProfile) -> None:
        status_text = {
            "disconnected": "终端未连接",
            "connecting": "终端连接中",
            "connected": "终端已连接",
            "failed": "终端失败",
        }.get(self.terminal_status, "终端未连接")
        self.make_header(profile, self.content, status_text)

        controls = ttk.Frame(self.content, padding=(12, 0, 12, 10))
        controls.pack(fill=tk.X)
        ttk.Button(controls, text="配置", command=lambda: self.edit_profile(profile)).pack(side=tk.LEFT)
        ttk.Button(controls, text="刷新文件", command=lambda: self.refresh_files(profile)).pack(side=tk.LEFT, padx=6)
        ttk.Button(controls, text="原生终端", command=lambda: self.open_native_terminal(profile)).pack(side=tk.LEFT)
        if self.terminal_profile_id == profile.id and self.terminal_status in {"connecting", "connected"}:
            ttk.Button(controls, text="断开终端", command=self.disconnect_terminal, style="Primary.TButton").pack(
                side=tk.RIGHT
            )
        else:
            ttk.Button(controls, text="连接终端", command=lambda: self.connect_terminal(profile), style="Primary.TButton").pack(
                side=tk.RIGHT
            )

        panes = ttk.PanedWindow(self.content, orient=tk.HORIZONTAL)
        panes.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 12))

        terminal_frame = ttk.Frame(panes)
        panes.add(terminal_frame, weight=1)
        term_bar = ttk.Frame(terminal_frame)
        term_bar.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(term_bar, text="SSH 终端", font=("Microsoft YaHei UI", 10, "bold")).pack(side=tk.LEFT)
        ttk.Button(term_bar, text="清空", command=self.clear_terminal).pack(side=tk.RIGHT)
        ttk.Button(term_bar, text="Ctrl+C", command=self.send_ctrl_c).pack(side=tk.RIGHT, padx=6)
        self.terminal_text = tk.Text(
            terminal_frame,
            wrap=tk.WORD,
            background="#101418",
            foreground="#e4e8ec",
            insertbackground="#31c46f",
            font=("Consolas", 10),
        )
        self.terminal_text.pack(fill=tk.BOTH, expand=True)
        self.terminal_text.insert("1.0", getattr(self, "_terminal_text", ""))
        command_row = ttk.Frame(terminal_frame)
        command_row.pack(fill=tk.X, pady=(6, 0))
        self.command_var = tk.StringVar()
        command_entry = ttk.Entry(command_row, textvariable=self.command_var)
        command_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        command_entry.bind("<Return>", lambda _event: self.send_terminal_command())
        ttk.Button(command_row, text="发送", command=self.send_terminal_command).pack(side=tk.RIGHT, padx=(6, 0))

        files_frame = ttk.Frame(panes)
        panes.add(files_frame, weight=1)
        self.build_file_browser(files_frame, profile)

    def connect_terminal(self, profile: SSHProfile) -> None:
        self.disconnect_terminal()
        self.terminal_profile_id = profile.id
        self.terminal_status = "connecting"
        self._terminal_text = ""
        self.terminal = TerminalSession(profile, self.append_terminal_output, self.on_terminal_status)
        self.terminal.start()
        self.refresh_sidebar()
        self.render_selected_profile()

    def disconnect_terminal(self) -> None:
        if self.terminal is not None:
            self.terminal.close()
            self.terminal = None
        self.terminal_status = "disconnected"
        self.terminal_profile_id = None
        self.refresh_sidebar()

    def on_terminal_status(self, status: str, message: str | None) -> None:
        def apply() -> None:
            self.terminal_status = status
            if status in {"failed", "disconnected"}:
                self.terminal_profile_id = None
            self.refresh_sidebar()
            self.render_selected_profile()
            if message:
                self.append_terminal_output(message + "\n")

        self.post(apply)

    def append_terminal_output(self, text: str) -> None:
        def apply() -> None:
            self._terminal_text = (getattr(self, "_terminal_text", "") + text)[-100000:]
            if hasattr(self, "terminal_text") and self.terminal_text.winfo_exists():
                self.terminal_text.delete("1.0", tk.END)
                self.terminal_text.insert("1.0", self._terminal_text)
                self.terminal_text.see(tk.END)

        self.post(apply)

    def clear_terminal(self) -> None:
        self._terminal_text = ""
        if hasattr(self, "terminal_text") and self.terminal_text.winfo_exists():
            self.terminal_text.delete("1.0", tk.END)

    def send_ctrl_c(self) -> None:
        if self.terminal is not None:
            self.terminal.send("\x03")

    def send_terminal_command(self) -> None:
        text = self.command_var.get()
        if self.terminal is not None and self.terminal_status == "connected":
            self.terminal.send(text + "\n")
            self.command_var.set("")
        else:
            messagebox.showinfo(APP_NAME, "请先连接终端。")

    def open_native_terminal(self, profile: SSHProfile) -> None:
        command = subprocess.list2cmdline(["ssh"] + profile.terminal_ssh_args(include_batch_mode=False))
        try:
            if sys.platform == "win32":
                creation_flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
                subprocess.Popen(["cmd.exe", "/k", command], creationflags=creation_flags)
            else:
                messagebox.showinfo(APP_NAME, command)
        except Exception as exc:
            messagebox.showerror(APP_NAME, f"打开原生终端失败：{exc}")

    def build_file_browser(self, parent: ttk.Frame, profile: SSHProfile) -> None:
        top = ttk.Frame(parent)
        top.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(top, text="远程文件", font=("Microsoft YaHei UI", 10, "bold")).pack(side=tk.LEFT)
        ttk.Label(top, text=self.sftp_status, style="Muted.TLabel").pack(side=tk.RIGHT)

        path_row = ttk.Frame(parent)
        path_row.pack(fill=tk.X, pady=(0, 6))
        ttk.Button(path_row, text="上级", command=lambda: self.go_parent(profile)).pack(side=tk.LEFT)
        self.remote_path_var = tk.StringVar(value=self.current_remote_path)
        path_entry = ttk.Entry(path_row, textvariable=self.remote_path_var)
        path_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6)
        path_entry.bind("<Return>", lambda _event: self.refresh_files(profile, self.remote_path_var.get()))
        ttk.Button(path_row, text="打开", command=lambda: self.refresh_files(profile, self.remote_path_var.get())).pack(
            side=tk.LEFT
        )

        action_row = ttk.Frame(parent)
        action_row.pack(fill=tk.X, pady=(0, 6))
        self.filter_var = tk.StringVar()
        self.filter_var.trace_add("write", lambda *_: self.populate_file_tree())
        ttk.Entry(action_row, textvariable=self.filter_var).pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(action_row, text="刷新", command=lambda: self.refresh_files(profile)).pack(side=tk.LEFT, padx=6)
        ttk.Button(action_row, text="上传", command=lambda: self.upload_file(profile)).pack(side=tk.LEFT)
        ttk.Button(action_row, text="下载", command=lambda: self.download_selected(profile)).pack(side=tk.LEFT, padx=(6, 0))

        columns = ("modified", "size", "kind")
        self.file_tree = ttk.Treeview(parent, columns=columns, show="tree headings", selectmode="browse")
        self.file_tree.heading("#0", text="名称")
        self.file_tree.heading("modified", text="修改时间")
        self.file_tree.heading("size", text="大小")
        self.file_tree.heading("kind", text="类型")
        self.file_tree.column("#0", width=260)
        self.file_tree.column("modified", width=145)
        self.file_tree.column("size", width=80, anchor=tk.E)
        self.file_tree.column("kind", width=70)
        self.file_tree.pack(fill=tk.BOTH, expand=True)
        self.file_tree.bind("<Double-1>", lambda _event: self.open_selected_remote(profile))
        self.populate_file_tree()

    def selected_remote_entry(self) -> RemoteFileEntry | None:
        if not hasattr(self, "file_tree"):
            return None
        selected = self.file_tree.selection()
        if not selected:
            return None
        path = selected[0]
        return next((entry for entry in self.remote_entries if entry.path == path), None)

    def populate_file_tree(self) -> None:
        if not hasattr(self, "file_tree") or not self.file_tree.winfo_exists():
            return
        self.file_tree.delete(*self.file_tree.get_children())
        needle = self.filter_var.get().strip().lower() if hasattr(self, "filter_var") else ""
        for entry in self.remote_entries:
            if needle and needle not in entry.name.lower():
                continue
            icon_name = "📁 " if entry.is_dir else "📄 "
            self.file_tree.insert(
                "",
                tk.END,
                iid=entry.path,
                text=icon_name + entry.name,
                values=(entry.modified, entry.size, entry.kind),
            )

    def refresh_files(self, profile: SSHProfile, path: str | None = None) -> None:
        if path is None:
            remote_path = self.remote_path_var.get() if hasattr(self, "remote_path_var") else self.current_remote_path
        else:
            remote_path = path
        remote_path = remote_path.strip()
        remote_path = remote_path or "."
        self.sftp_status = "文件处理中"
        self.render_selected_profile()

        def work() -> None:
            try:
                entries, actual = self.list_remote_directory(profile, remote_path)

                def apply() -> None:
                    self.remote_entries = entries
                    self.current_remote_path = actual
                    self.sftp_status = "文件完成"
                    self.render_selected_profile()

                self.post(apply)
            except Exception as exc:
                self.post(lambda: self.on_sftp_error(str(exc)))

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

    def on_sftp_error(self, message: str) -> None:
        self.sftp_status = "文件失败"
        messagebox.showerror(APP_NAME, message)
        self.render_selected_profile()

    def go_parent(self, profile: SSHProfile) -> None:
        path = self.current_remote_path.strip()
        if not path or path in {".", "/"}:
            return
        parent = posixpath.dirname(path.rstrip("/")) or "/"
        self.refresh_files(profile, parent)

    def open_selected_remote(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is not None and entry.is_dir:
            self.refresh_files(profile, entry.path)

    def upload_file(self, profile: SSHProfile) -> None:
        local = filedialog.askopenfilename(title="选择要上传的文件")
        if not local:
            directory = filedialog.askdirectory(title="或选择要上传的文件夹")
            local = directory
        if not local:
            return
        remote_dir = self.current_remote_path or "."
        self.sftp_status = "正在上传"
        self.render_selected_profile()

        def work() -> None:
            try:
                self.upload_path(profile, Path(local), remote_dir)
                self.post(lambda: self.refresh_files(profile, remote_dir))
            except Exception as exc:
                self.post(lambda: self.on_sftp_error(str(exc)))

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
                        local_file = Path(root) / filename
                        sftp.put(str(local_file), posixpath.join(remote_root, filename))
            else:
                sftp.put(str(local_path), destination)
        finally:
            connection.close()

    def download_selected(self, profile: SSHProfile) -> None:
        entry = self.selected_remote_entry()
        if entry is None:
            messagebox.showinfo(APP_NAME, "请先选择一个远程文件或文件夹。")
            return
        target_dir = filedialog.askdirectory(title="选择下载位置")
        if not target_dir:
            return
        self.sftp_status = "正在下载"
        self.render_selected_profile()

        def work() -> None:
            try:
                self.download_path(profile, entry, Path(target_dir))
                self.post(lambda: self.finish_sftp("文件完成"))
            except Exception as exc:
                self.post(lambda: self.on_sftp_error(str(exc)))

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

    def finish_sftp(self, status: str) -> None:
        self.sftp_status = status
        self.render_selected_profile()

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
        if messagebox.askyesno(APP_NAME, "确定删除当前配置吗？"):
            self.store.delete_selected()
            self.refresh_sidebar()
            self.render_selected_profile()

    def edit_profile(self, profile: SSHProfile) -> None:
        ProfileEditor(self, profile, self.save_profile)

    def save_profile(self, profile: SSHProfile) -> None:
        self.store.update(profile)
        self.store.selected_profile_id = profile.id
        self.refresh_sidebar()
        self.render_selected_profile()

    def on_close(self) -> None:
        self.disconnect_tunnel()
        self.disconnect_terminal()
        self.destroy()


def main() -> int:
    app = App()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
