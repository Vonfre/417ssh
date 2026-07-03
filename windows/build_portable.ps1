$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$versionFile = Join-Path $PSScriptRoot "VERSION"
$version = if ($env:VERSION) { $env:VERSION } elseif (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { "0.4.3" }
$appName = "417ssh"
$exePath = Join-Path $PSScriptRoot "dist\417ssh.exe"
$stagingRoot = Join-Path $PSScriptRoot "build\portable"
$portableDir = Join-Path $stagingRoot $appName
$zipPath = Join-Path $PSScriptRoot "dist\$appName-$version-win-portable.zip"

if (-not (Test-Path $exePath)) {
    & "$PSScriptRoot\build_windows.ps1"
}

if (-not (Test-Path $exePath)) {
    throw "未找到 PyInstaller 输出：$exePath"
}

if (Test-Path $stagingRoot) {
    Remove-Item -Recurse -Force $stagingRoot
}
New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $zipPath) | Out-Null

Copy-Item $exePath (Join-Path $portableDir "$appName.exe") -Force
Copy-Item (Join-Path $PSScriptRoot "VERSION") (Join-Path $portableDir "VERSION") -Force

$readme = @"
417ssh Windows portable

使用方式：
1. 解压整个文件夹。
2. 双击 417ssh.exe 运行。
3. 配置文件仍保存在 %APPDATA%\417ssh\profiles.json。

如果 Windows SmartScreen 提示未知发布者，请选择“更多信息”后继续运行。发布正式版本时建议后续补代码签名。
"@
Set-Content -Path (Join-Path $portableDir "README.txt") -Value $readme -Encoding UTF8

if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

Compress-Archive -Path $portableDir -DestinationPath $zipPath -CompressionLevel Optimal

if (-not (Test-Path $zipPath)) {
    throw "Compress-Archive did not create ZIP: $zipPath"
}

Write-Host ""
Write-Host "Built: $zipPath"
