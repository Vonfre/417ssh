from __future__ import annotations

import posixpath
import re
import shlex
import urllib.parse


DIRECTORY_PROBE_OSC_PREFIX = "417ssh;pwd="
DIRECTORY_PROBE_COMMAND = " printf '\\033]417ssh;pwd=%s\\007' \"$PWD\""
DIRECTORY_PROBE_PATTERN = re.compile(r"\x1b]417ssh;pwd=([^\x07\x1b]*)(?:\x07|\x1b\\)")
OSC7_PATTERN = re.compile(r"\x1b]7;([^\x07\x1b]*)(?:\x07|\x1b\\)")


def normalize_terminal_directory(path: str) -> str:
    path = path.strip()
    if path == "~" or path.startswith("~/"):
        suffix = path[2:] if path.startswith("~/") else ""
        normalized = posixpath.normpath("/" + suffix).lstrip("/")
        return "~" if normalized == "." else f"~/{normalized}"
    return posixpath.normpath(path)


def path_from_osc7_payload(payload: str) -> str:
    if payload.startswith("file://"):
        without_scheme = payload[len("file://") :]
        slash_index = without_scheme.find("/")
        if slash_index >= 0:
            return normalize_terminal_directory(urllib.parse.unquote(without_scheme[slash_index:]))
        return ""
    return normalize_terminal_directory(urllib.parse.unquote(payload))


def path_from_probe_payload(payload: str) -> str:
    return normalize_terminal_directory(payload)


def cd_target_from_words(words: list[str]) -> str:
    parsing_options = True
    for word in words[1:]:
        if parsing_options and word == "--":
            parsing_options = False
            continue
        if parsing_options and word in {"-L", "-P", "-e", "-@"}:
            continue
        return word
    return "~"


def resolve_terminal_directory(path: str, base: str | None) -> str:
    trimmed = path.strip()
    if not trimmed:
        return "~"
    if trimmed == "~" or trimmed.startswith("~/") or trimmed.startswith("/"):
        return normalize_terminal_directory(trimmed)
    if not base:
        return trimmed
    if base == "~":
        return normalize_terminal_directory(f"~/{trimmed}")
    return normalize_terminal_directory(posixpath.join(base, trimmed))


def directory_after_cd_command(command: str, base: str | None) -> str | None:
    try:
        words = shlex.split(command.strip(), posix=True)
    except ValueError:
        return None
    if not words or words[0] != "cd":
        return None
    target = cd_target_from_words(words)
    if target == "-":
        return None
    return resolve_terminal_directory(target, base)


def is_probably_truncated_directory(existing: str, candidate: str) -> bool:
    if not existing or not candidate or existing == candidate:
        return False
    if not existing.startswith(candidate):
        return False
    if len(existing) <= len(candidate):
        return False
    if existing[len(candidate)] == "/":
        return False
    return posixpath.dirname(existing) == posixpath.dirname(candidate)
