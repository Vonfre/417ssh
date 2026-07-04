$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = $env:VERSION
if ([string]::IsNullOrWhiteSpace($version)) {
    $version = (Get-Content -Path (Join-Path $root "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "VERSION is empty"
}

Set-Content -Path (Join-Path $root "VERSION") -Value $version -Encoding UTF8

$dist = Join-Path $root "dist"
$publish = Join-Path $dist "publish"
$appDir = Join-Path $dist "417ssh"
$zipPath = Join-Path $dist "417ssh-$version-win-portable.zip"

if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

New-Item -ItemType Directory -Force -Path $dist | Out-Null

dotnet restore (Join-Path $root "417ssh.Native.csproj")
dotnet publish (Join-Path $root "417ssh.Native.csproj") `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=false `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:Version=$version `
    -p:FileVersion="$version.0" `
    -p:AssemblyVersion="$version.0" `
    -p:InformationalVersion=$version `
    -o $publish

New-Item -ItemType Directory -Force -Path $appDir | Out-Null
Copy-Item -Path (Join-Path $publish "*") -Destination $appDir -Recurse -Force
Copy-Item -Path (Join-Path $root "README-Windows.txt") -Destination (Join-Path $appDir "README-Windows.txt") -Force

Compress-Archive -Path $appDir -DestinationPath $zipPath -Force
Get-Item $zipPath | Format-List FullName,Length
