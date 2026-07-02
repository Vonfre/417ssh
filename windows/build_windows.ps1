$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$python = "python"
$pythonArgs = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    $python = "py"
    $pythonArgs = @("-3")
}

& $python @pythonArgs -m pip install -r requirements-build.txt

$pyInstallerArgs = @(
    "--noconsole",
    "--onefile",
    "--clean",
    "--name", "417ssh",
    "--collect-all", "PySide6",
    "--hidden-import", "PySide6.QtWebEngineWidgets",
    "--add-data", "assets\logo.jpg;assets",
    "--add-data", "VERSION;.",
    "--add-data", "src\417ssh_windows.py;.",
    "src\417ssh_qt.py"
)

& $python @pythonArgs -m PyInstaller @pyInstallerArgs

if (-not (Test-Path "$PSScriptRoot\dist\417ssh.exe")) {
    throw "PyInstaller did not create dist\417ssh.exe"
}

Write-Host ""
Write-Host "Built: $PSScriptRoot\dist\417ssh.exe"
