<#
.SYNOPSIS
  Builds Frogster for Android and Windows and packs both into client\dist.

.EXAMPLE
  .\tool\build_release.ps1 -Server chat.example.com -Version 1.0.0

  -Server       address offered on the sign-in screen (people can still
                type another one).
  -Fingerprint  only for a server on a bare IP with its own certificate:
                what `sudo frogster fingerprint` prints on the server.
                Built in, so nobody has to type it.
  -Version  shown under Settings -> About.

The Android build is signed with android\key.properties when it exists
(see tool\README-release.md), otherwise with the debug key.
#>
param(
  [string]$Server = "",
  [string]$Fingerprint = "",
  [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$client = Split-Path -Parent $PSScriptRoot
Set-Location $client

$defines = @("--dart-define=FROGSTER_VERSION=$Version")
if ($Server) { $defines += "--dart-define=FROGSTER_SERVER=$Server" }
if ($Fingerprint) {
  if (-not $Server) { throw "-Fingerprint needs -Server: it belongs to that server" }
  $defines += "--dart-define=FROGSTER_FINGERPRINT=$Fingerprint"
}

$dist = Join-Path $client "dist"
New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host "== Android" -ForegroundColor Cyan
if (-not (Test-Path "android\key.properties")) {
  Write-Warning "android\key.properties not found: signing with the debug key."
}
flutter build apk --release @defines
if ($LASTEXITCODE -ne 0) { throw "Android build failed" }
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" (Join-Path $dist "Frogster-$Version.apk") -Force

Write-Host "== Windows" -ForegroundColor Cyan
flutter build windows --release @defines
if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }

$release = "build\windows\x64\runner\Release"
# The Visual C++ runtime is on most PCs, but not all; shipping it next to
# the exe means a friend's machine without it still starts the app.
foreach ($dll in "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll") {
  $source = Join-Path $env:SystemRoot "System32\$dll"
  if (Test-Path $source) { Copy-Item $source $release -Force }
}

$zip = Join-Path $dist "Frogster-$Version-windows.zip"
if (Test-Path $zip) { Remove-Item $zip }
$staging = Join-Path $env:TEMP "Frogster-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Copy-Item $release $staging -Recurse
Compress-Archive -Path $staging -DestinationPath $zip
Remove-Item $staging -Recurse -Force

Write-Host ""
Write-Host "Done:" -ForegroundColor Green
Get-ChildItem $dist | ForEach-Object { "  {0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB) }
