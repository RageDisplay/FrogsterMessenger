<#
.SYNOPSIS
  Updates the Frogster server from this computer, over SSH.

.EXAMPLE
  .\deploy\update-server.ps1 root@203.0.113.5

  Connects, then runs `sudo frogster update` on the server: a database
  backup, the latest code from GitHub, a rebuild, and a rollback on its own
  if the new version does not start. Its output appears here as it runs.

  Push your changes to GitHub first: the server takes the code from there.

  -Force   rebuild even when the code has not changed.
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Target,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw "ssh not found. Settings -> System -> Optional features -> add 'OpenSSH Client'."
}

$command = "sudo frogster update"
if ($Force) { $command += " --force" }

# -t gives sudo a terminal, so it can ask for a password when it needs one.
ssh -t $Target $command
if ($LASTEXITCODE -ne 0) {
  throw "The update did not finish (exit code $LASTEXITCODE). The output above says why."
}
