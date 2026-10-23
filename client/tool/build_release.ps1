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

The Android build is signed with the key that key.properties names, found in
$env:FROGSTER_SIGNING_DIR, %USERPROFILE%\.frogster\signing or android\
(see tool\README-release.md); without one, with the debug key.
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
  # The same check the app makes. A typo here would otherwise be dropped
  # silently by the app and only show up as the fingerprint prompt.
  $hex = ($Fingerprint -replace '[\s:\-]', '').ToUpper()
  if ($hex -notmatch '^[0-9A-F]{32,64}$') {
    throw "-Fingerprint '$Fingerprint' is not what 'sudo frogster fingerprint' prints (8 groups of 4 characters 0-9/A-F)"
  }
  $defines += "--dart-define=FROGSTER_FINGERPRINT=$Fingerprint"
}

Write-Host "Server:      $(if ($Server) { $Server } else { '(none - typed on the sign-in screen)' })"
Write-Host "Fingerprint: $(if ($Fingerprint) { $Fingerprint } else { '(none)' })"
Write-Host "Version:     $Version"
Write-Host ""

# Confirms a built binary really carries the server and fingerprint: both
# end up in the compiled Dart code as plain strings.
function Assert-BuiltIn([byte[]]$bytes, [string]$what) {
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  foreach ($value in @($Server, $Fingerprint)) {
    if ($value -and -not $text.Contains($value)) {
      throw "$what was built without '$value'. Run 'flutter clean' and build again."
    }
  }
  Write-Host "$what carries the server address and fingerprint." -ForegroundColor Green
}

$dist = Join-Path $client "dist"
New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host "== Android" -ForegroundColor Cyan
# The same places android\app\build.gradle.kts looks in, first found wins.
$keyFile = @(
  $(if ($env:FROGSTER_SIGNING_DIR) { Join-Path $env:FROGSTER_SIGNING_DIR "key.properties" }),
  (Join-Path $env:USERPROFILE ".frogster\signing\key.properties"),
  "android\key.properties"
) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
if ($keyFile) {
  Write-Host "Signing key: $(Resolve-Path $keyFile)"
} else {
  Write-Warning "No key.properties (see tool\README-release.md): signing with the debug key. Phones with a release-signed Frogster will not take this APK as an update."
}
flutter build apk --release @defines
if ($LASTEXITCODE -ne 0) { throw "Android build failed" }
$apk = "build\app\outputs\flutter-apk\app-release.apk"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
try {
  $stream = $archive.GetEntry("lib/arm64-v8a/libapp.so").Open()
  $buffer = New-Object System.IO.MemoryStream
  $stream.CopyTo($buffer)
  $stream.Dispose()
  Assert-BuiltIn $buffer.ToArray() "The APK"
} finally { $archive.Dispose() }
Copy-Item $apk (Join-Path $dist "Frogster-$Version.apk") -Force

Write-Host "== Windows" -ForegroundColor Cyan
flutter build windows --release @defines
if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }

$release = "build\windows\x64\runner\Release"
Assert-BuiltIn ([System.IO.File]::ReadAllBytes((Resolve-Path "$release\data\app.so"))) "The Windows build"
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
