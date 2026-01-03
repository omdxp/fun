param(
  [ValidateSet('User','Machine')]
  [string]$Scope = 'User',
  [string]$Prefix = ''
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Machine install requires an elevated PowerShell (Run as Administrator)."
  }
}

$bundleRoot = $PSScriptRoot
$srcBin = Join-Path $bundleRoot 'bin'
$srcShare = Join-Path $bundleRoot 'share\fun'

if (-not (Test-Path $srcBin)) { throw "Missing 'bin' directory next to installer." }
if (-not (Test-Path $srcShare)) { throw "Missing 'share\\fun' directory next to installer." }

if ($Prefix -ne '') {
  $destPrefix = $Prefix
} elseif ($Scope -eq 'Machine') {
  Require-Admin
  $destPrefix = Join-Path $env:ProgramFiles 'fun'
} else {
  $destPrefix = Join-Path $env:LOCALAPPDATA 'fun'
}

$destBin = Join-Path $destPrefix 'bin'
$destShare = Join-Path $destPrefix 'share\fun'
${destStdlibRoot} = Join-Path $destShare 'stdlib'

New-Item -ItemType Directory -Force -Path $destBin | Out-Null
New-Item -ItemType Directory -Force -Path $destShare | Out-Null

Copy-Item -Force -Recurse (Join-Path $srcBin '*') $destBin
Copy-Item -Force -Recurse $srcShare $destPrefix\share

# Add to PATH (User scope by default)
$pathScope = if ($Scope -eq 'Machine') { 'Machine' } else { 'User' }
$currentPath = [Environment]::GetEnvironmentVariable('Path', $pathScope)
if ($null -eq $currentPath) { $currentPath = '' }

$binPath = $destBin
if ($currentPath -notlike "*$binPath*") {
  $newPath = if ($currentPath.Trim().Length -eq 0) { $binPath } else { "$currentPath;$binPath" }
  [Environment]::SetEnvironmentVariable('Path', $newPath, $pathScope)
}

# Point tooling at the installed stdlib.
[Environment]::SetEnvironmentVariable('FUN_STDLIB_DIR', $destStdlibRoot, $pathScope)

Write-Host "Installed fun to: $destPrefix"
Write-Host "Stdlib installed to: $destShare"
Write-Host "FUN_STDLIB_DIR set to: $destStdlibRoot"
Write-Host "You may need to restart your terminal for PATH changes to take effect."
