from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "windows" / "src"))

from terminal_paths import (  # noqa: E402
    DIRECTORY_PROBE_PATTERN,
    OSC7_PATTERN,
    directory_after_cd_command,
    is_probably_truncated_directory,
    path_from_osc7_payload,
    path_from_probe_payload,
)


def test_cd_paths_keep_special_characters() -> None:
    base = "/data/project"
    assert directory_after_cd_command("cd 0_data", base) == "/data/project/0_data"
    assert directory_after_cd_command("cd 2.docker", base) == "/data/project/2.docker"
    assert directory_after_cd_command("cd '中文 目录(1)'", base) == "/data/project/中文 目录(1)"
    assert directory_after_cd_command("cd -- /data/project/0_data", "/tmp") == "/data/project/0_data"


def test_osc7_and_probe_paths_keep_special_characters() -> None:
    assert path_from_osc7_payload("file://remote-host/data/project/0_data") == "/data/project/0_data"
    assert path_from_osc7_payload("file://remote-host/data/project/2.docker") == "/data/project/2.docker"
    assert path_from_osc7_payload("file://remote-host/data/project/%E4%B8%AD%E6%96%87%20%E7%9B%AE%E5%BD%95") == "/data/project/中文 目录"
    assert path_from_probe_payload("/data/project/0_data") == "/data/project/0_data"


def test_control_sequence_patterns_capture_full_paths() -> None:
    probe = "\x1b]417ssh;pwd=/data/project/0_data\x07"
    osc7 = "\x1b]7;file://remote-host/data/project/2.docker\x07"
    assert DIRECTORY_PROBE_PATTERN.search(probe).group(1) == "/data/project/0_data"  # type: ignore[union-attr]
    assert path_from_osc7_payload(OSC7_PATTERN.search(osc7).group(1)) == "/data/project/2.docker"  # type: ignore[union-attr]


def test_truncated_directory_guard() -> None:
    assert is_probably_truncated_directory("/data/project/0_data", "/data/project/0")
    assert is_probably_truncated_directory("/data/project/2.docker", "/data/project/2")
    assert not is_probably_truncated_directory("/data/project/0_data", "/data/project/0_data")


if __name__ == "__main__":
    test_cd_paths_keep_special_characters()
    test_osc7_and_probe_paths_keep_special_characters()
    test_control_sequence_patterns_capture_full_paths()
    test_truncated_directory_guard()
    print("terminal path sync tests passed")
