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
    throw "Machine uninstall requires an elevated PowerShell (Run as Administrator)."
  }
}

if ($Prefix -ne '') {
  $destPrefix = $Prefix
} elseif ($Scope -eq 'Machine') {
  Require-Admin
  $destPrefix = Join-Path $env:ProgramFiles 'fun'
} else {
  $destPrefix = Join-Path $env:LOCALAPPDATA 'fun'
}

$destBin = Join-Path $destPrefix 'bin'
${destStdlibRoot} = Join-Path (Join-Path $destPrefix 'share\fun') 'stdlib'

if (Test-Path $destPrefix) {
  Remove-Item -Recurse -Force $destPrefix
}

$pathScope = if ($Scope -eq 'Machine') { 'Machine' } else { 'User' }
$currentPath = [Environment]::GetEnvironmentVariable('Path', $pathScope)
if ($null -ne $currentPath) {
  $parts = $currentPath -split ';' | Where-Object { $_ -and ($_ -ne $destBin) }
  $newPath = ($parts -join ';')
  [Environment]::SetEnvironmentVariable('Path', $newPath, $pathScope)
}

$curStdlib = [Environment]::GetEnvironmentVariable('FUN_STDLIB_DIR', $pathScope)
if ($null -ne $curStdlib -and $curStdlib -eq $destStdlibRoot) {
  [Environment]::SetEnvironmentVariable('FUN_STDLIB_DIR', $null, $pathScope)
}

Write-Host "Uninstalled fun from: $destPrefix"
