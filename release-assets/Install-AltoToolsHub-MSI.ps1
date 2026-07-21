[CmdletBinding()]
param(
  [ValidateSet("Install", "Repair", "Uninstall")]
  [string]$Action = "Install",
  [string]$MsiPath = (Join-Path $PSScriptRoot "AltoToolsHubSetup.msi"),
  [switch]$Quiet,
  [switch]$NoLaunch,
  [switch]$RequireSignature
)

$ErrorActionPreference = "Stop"
$ProductName = "Alto Tools Hub"
$InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\AltoTech\Alto Tools Hub"
$HubExecutable = Join-Path $InstallRoot "Alto Tools Hub.exe"
$StateRoot = Join-Path $env:LOCALAPPDATA "AltoTech\Alto Tools Hub"
$LogRoot = Join-Path $StateRoot "Logs"

function Test-InstallerChecksum {
  param([string]$Installer)

  $checksumPath = "$Installer.sha256"
  if (!(Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "Checksum file not found: $checksumPath"
  }

  $checksumText = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
  $match = [regex]::Match($checksumText, "\A([0-9a-fA-F]{64})\s+AltoToolsHubSetup\.msi\z")
  if (!$match.Success) {
    throw "Checksum file has an invalid format."
  }

  $expected = $match.Groups[1].Value.ToLowerInvariant()
  $actual = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "Installer checksum verification failed. Download the release files again."
  }
  Write-Host "SHA-256 verification passed."
}

function Test-InstallerSignature {
  param([string]$Installer)

  $signature = Get-AuthenticodeSignature -LiteralPath $Installer
  if ($signature.Status -eq "Valid") {
    Write-Host "Signature verification passed: $($signature.SignerCertificate.Subject)"
    return
  }
  if ($RequireSignature) {
    throw "Installer signature is not valid: $($signature.Status)"
  }
  Write-Warning "Installer signature status: $($signature.Status). SHA-256 was verified."
}

function Stop-AltoToolsHub {
  try {
    $shutdownEvent = [System.Threading.EventWaitHandle]::OpenExisting("Local\AltoToolsHub.Shutdown")
    $shutdownEvent.Set() | Out-Null
    $shutdownEvent.Dispose()
  } catch {}

  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    $hubProcesses = @(Get-Process -Name "Alto Tools Hub" -ErrorAction SilentlyContinue |
      Where-Object {
        try {
          $_.Path -and $_.Path.Equals($HubExecutable, [StringComparison]::OrdinalIgnoreCase)
        } catch {
          $false
        }
      })
    if ($hubProcesses.Count -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)

  $hubProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
}

if (!(Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
  throw "MSI installer not found: $MsiPath"
}
$ResolvedMsi = (Resolve-Path -LiteralPath $MsiPath).Path

Write-Host "$Action $ProductName"
Test-InstallerChecksum -Installer $ResolvedMsi
Test-InstallerSignature -Installer $ResolvedMsi
Stop-AltoToolsHub

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
$logPath = Join-Path $LogRoot "msi-$($Action.ToLowerInvariant())-$timestamp.log"
$quotedMsi = '"' + $ResolvedMsi + '"'
$quotedLog = '"' + $logPath + '"'
$operation = switch ($Action) {
  "Install" { "/i" }
  "Repair" { "/fa" }
  "Uninstall" { "/x" }
}
$arguments = @($operation, $quotedMsi, "/norestart", "/L*v", $quotedLog)
if ($Quiet) {
  $arguments += "/qn"
}

$installer = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
if ($installer.ExitCode -notin @(0, 1641, 3010)) {
  throw "Windows Installer failed with exit code $($installer.ExitCode). Log: $logPath"
}

if ($Action -ne "Uninstall" -and !$NoLaunch -and (Test-Path -LiteralPath $HubExecutable)) {
  Start-Process -FilePath $HubExecutable -WorkingDirectory $InstallRoot
}

Write-Host "$Action completed successfully. Log: $logPath"
if ($installer.ExitCode -in @(1641, 3010)) {
  Write-Host "Windows requested a restart to finish the operation."
}
