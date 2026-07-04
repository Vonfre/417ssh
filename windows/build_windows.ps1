$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$python = "python"
$pythonArgs = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    $python = "py"
    $pythonArgs = @("-3")
}

& $python @pythonArgs -m pip install -r requirements-build.txt

$iconPath = Join-Path $PSScriptRoot "assets\logo.ico"
if (-not (Test-Path $iconPath)) {
    $iconScript = @'
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = root / "assets" / "logo.jpg"
target = root / "assets" / "logo.ico"
image = Image.open(source).convert("RGBA")
image.save(target, sizes=[(16, 16), (32, 32), (48, 48), (128, 128), (256, 256)])
'@
    $scriptPath = Join-Path $PSScriptRoot "build\make_ico.py"
    New-Item -ItemType Directory -Force -Path (Split-Path $scriptPath) | Out-Null
    Set-Content -Path $scriptPath -Value $iconScript -Encoding UTF8
    & $python @pythonArgs $scriptPath
}

$pyInstallerArgs = @(
    "--noconsole",
    "--clean",
    "--name", "417ssh",
    "--icon", "assets\logo.ico",
    "--collect-all", "paramiko",
    "--hidden-import", "dataclasses",
    "--hidden-import", "queue",
    "--hidden-import", "socket",
    "--hidden-import", "uuid",
    "--hidden-import", "PySide6.QtWebChannel",
    "--hidden-import", "PySide6.QtWebEngineWidgets",
    "--exclude-module", "tkinter",
    "--exclude-module", "PIL",
    "--exclude-module", "PIL.ImageTk",
    "--add-data", "assets;assets",
    "--add-data", "VERSION;.",
    "--add-data", "src\417ssh_windows.py;.",
    "src\417ssh_qt.py"
)

& $python @pythonArgs -m PyInstaller @pyInstallerArgs

$exePath = Join-Path $PSScriptRoot "dist\417ssh\417ssh.exe"
if (-not (Test-Path $exePath)) {
    throw "PyInstaller did not create $exePath"
}

Write-Host ""
Write-Host "Built: $exePath"
