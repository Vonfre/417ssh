$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$versionFile = Join-Path $PSScriptRoot "VERSION"
$version = if ($env:VERSION) { $env:VERSION } elseif (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { "0.5.1" }
throw "MSI 打包暂未适配当前 onedir portable 结构；官方 Windows 发布包请使用 build_portable.ps1 生成 417ssh-$version-win-portable.zip。"

$appName = "417ssh"
$manufacturer = "Vonfre"
$upgradeCode = "1F9AB05B-46B8-46E0-A7FB-4170E7F0417F"
$exePath = Join-Path $PSScriptRoot "dist\417ssh\417ssh.exe"
$iconPath = Join-Path $PSScriptRoot "assets\logo.ico"
$buildDir = Join-Path $PSScriptRoot "build\msi"
$wxsPath = Join-Path $buildDir "417ssh.wxs"
$msiPath = Join-Path $PSScriptRoot "dist\417ssh-$version-win.msi"

if (-not (Test-Path $exePath)) {
    & "$PSScriptRoot\build_windows.ps1"
}

if (-not (Test-Path $exePath)) {
    throw "未找到 PyInstaller 输出：$exePath"
}

$python = "python"
$pythonArgs = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    $python = "py"
    $pythonArgs = @("-3")
}

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

if (-not (Test-Path $iconPath)) {
    throw "未找到应用图标：$iconPath"
}

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    throw "未找到 WiX Toolset v4。请先安装：winget install WiXToolset.WiXToolset"
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $msiPath) | Out-Null

$wxs = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package
    Name="$appName"
    Manufacturer="$manufacturer"
    Version="$version"
    UpgradeCode="{$upgradeCode}"
    Scope="perUser">
    <MajorUpgrade DowngradeErrorMessage="已经安装了更新版本的 $appName。" />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="AppIcon" SourceFile="$iconPath" />

    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="INSTALLFOLDER" Name="$appName">
        <Component Id="AppExecutable" Guid="*">
          <File Id="AppExe" Source="$exePath" KeyPath="yes">
            <Shortcut
              Id="StartMenuShortcut"
              Directory="ApplicationProgramsFolder"
              Name="$appName"
              WorkingDirectory="INSTALLFOLDER"
              Icon="AppIcon"
              Advertise="no" />
          </File>
        </Component>
      </Directory>
    </StandardDirectory>

    <StandardDirectory Id="ProgramMenuFolder">
      <Directory Id="ApplicationProgramsFolder" Name="$appName">
        <Component Id="ApplicationProgramsFolderComponent" Guid="*">
          <RemoveFolder Id="ApplicationProgramsFolder" On="uninstall" />
          <RegistryValue
            Root="HKCU"
            Key="Software\$manufacturer\$appName"
            Name="installed"
            Type="integer"
            Value="1"
            KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>

    <Feature Id="MainFeature" Title="$appName" Level="1">
      <ComponentRef Id="AppExecutable" />
      <ComponentRef Id="ApplicationProgramsFolderComponent" />
    </Feature>
  </Package>
</Wix>
"@

Set-Content -Path $wxsPath -Value $wxs -Encoding UTF8
wix build $wxsPath -o $msiPath

if (-not (Test-Path $msiPath)) {
    throw "WiX did not create MSI: $msiPath"
}

Write-Host ""
Write-Host "Built: $msiPath"
