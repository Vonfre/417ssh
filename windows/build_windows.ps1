$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$python = "python"
$pythonArgs = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    $python = "py"
    $pythonArgs = @("-3")
}

& $python @pythonArgs -m pip install -r requirements-build.txt
& $python @pythonArgs -m PyInstaller --noconsole --onefile --name 417ssh --collect-all PySide6 --hidden-import PySide6.QtWebEngineWidgets --add-data "assets\logo.jpg;assets" "src\417ssh_qt.py"

Write-Host ""
Write-Host "Built: $PSScriptRoot\dist\417ssh.exe"
