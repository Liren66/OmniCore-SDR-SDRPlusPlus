# Builds the Windows x64 installer (Inno Setup) from the folder package.sh made.
#   powershell -NoProfile -File packaging/windows/build_installer.ps1 -HostDir ..\OmniCore-SDR-Host
# HostDir: an OmniCore Host checkout with its built driver assistant (tools\installer\och-driver.exe, libwdi.dll),
# the libusbK / libwdi licenses and source archives (third_party\driver) and the bundled Inno Setup 6.2.2 compiler.
param(
    [Parameter(Mandatory = $true)][string]$HostDir,
    [string]$PackageDir = '',
    [string]$OutputDir = '',
    [string]$InnoCompiler = ''
)
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$version = (Select-String -Path (Join-Path $src 'core\src\version.h') -Pattern 'VERSION_STR "(.*)"').Matches[0].Groups[1].Value
if (!$OutputDir) { $OutputDir = Join-Path $src 'release' }
if (!$PackageDir) { $PackageDir = Join-Path $OutputDir "OmniCore-SDR-SDRPlusPlus-$version-windows-x64" }
$HostDir = (Resolve-Path $HostDir).Path
if (!$InnoCompiler) { $InnoCompiler = Join-Path $HostDir 'tools\installer\inno-6.2.2\app\ISCC.exe' }
foreach ($f in @($InnoCompiler, (Join-Path $PackageDir 'sdrpp.exe'), (Join-Path $PackageDir 'omnicore.dll'), (Join-Path $PackageDir 'modules\omnicore_source.dll'))) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing: $f" }
}

# Driver assistant with its licenses and the corresponding sources (libwdi is LGPL)
$tools = Join-Path $HostDir 'tools\installer'
$driver = Join-Path $HostDir 'third_party\driver'
$stage = Join-Path ([IO.Path]::GetTempPath()) ("sdrpp-driver-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force (Join-Path $stage 'licenses\libusbK'), (Join-Path $stage 'licenses\libwdi'), (Join-Path $stage 'licenses\sources') | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $tools 'och-driver.exe'), (Join-Path $tools 'libwdi.dll') -Destination $stage
    Copy-Item -Path (Join-Path $driver 'libusbK-3.1.0.0-src\license\*') -Destination (Join-Path $stage 'licenses\libusbK')
    Copy-Item -LiteralPath (Join-Path $driver 'libwdi-1.5.1\COPYING'), (Join-Path $driver 'libwdi-1.5.1\COPYING-LGPL') -Destination (Join-Path $stage 'licenses\libwdi')
    Copy-Item -LiteralPath (Join-Path $driver 'downloads\libwdi-v1.5.1.zip'), (Join-Path $driver 'downloads\libusbK-3.1.0.0-src.7z') -Destination (Join-Path $stage 'licenses\sources')
    Copy-Item -LiteralPath (Join-Path $driver 'NOTICES.txt'), (Join-Path $driver 'SOURCES.json') -Destination (Join-Path $stage 'licenses')
    Copy-Item -LiteralPath (Join-Path $HostDir 'LICENSE') -Destination (Join-Path $stage 'licenses\LICENSE-OmniCore-Host.txt')
    @"
och-driver.exe is the OmniCore Host driver assistant: it installs the libusbK driver (libwdi) for VID 1A86 / PID 5537 only.
  och-driver check     query only
  och-driver install   install libusbK (administrator)
Source: https://github.com/Liren66/OmniCore-SDR-Host (tools/installer). libwdi and libusbK sources: licenses\sources.
"@ | Set-Content -Encoding ASCII (Join-Path $stage 'README.txt')

    & $InnoCompiler /Q ("/DPackageDir=" + (Resolve-Path $PackageDir).Path) ("/DDriverDir=" + $stage) ("/DOutputDir=" + $OutputDir) ("/DAppVersion=" + $version) (Join-Path $PSScriptRoot 'omnicore-sdrpp.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
}
finally {
    Remove-Item -Recurse -Force $stage
}
$setup = Join-Path $OutputDir "OmniCore-SDR-SDRPlusPlus-$version-windows-x64-setup.exe"
Get-Item $setup | Select-Object FullName, Length
