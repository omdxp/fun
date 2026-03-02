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
${destStdlibRoot} = Join-Path $destPrefix 'share\fun'

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

$curFunCc = [Environment]::GetEnvironmentVariable('FUN_CC', $pathScope)
if ($null -ne $curFunCc) {
  $c = $curFunCc.Trim('"')
  if ($c -eq 'cl /nologo /Fe{out} {src}' -or $c -eq 'zig') {
    [Environment]::SetEnvironmentVariable('FUN_CC', $null, $pathScope)
  }
}

$curFunCcArgs = [Environment]::GetEnvironmentVariable('FUN_CC_ARGS', $pathScope)
if ($null -ne $curFunCcArgs) {
  $a = $curFunCcArgs.Trim('"')
  if ($a -eq '' -or $a -eq 'cc') {
    [Environment]::SetEnvironmentVariable('FUN_CC_ARGS', $null, $pathScope)
  }
}

# Also clean up stale User-scoped values that may override Machine scope.
$userStdlib = [Environment]::GetEnvironmentVariable('FUN_STDLIB_DIR', 'User')
if ($null -ne $userStdlib) {
  $u = $userStdlib.Trim('"')
  $legacy = Join-Path $destStdlibRoot 'stdlib'
  if ($u -eq $destStdlibRoot -or $u -eq $legacy) {
    [Environment]::SetEnvironmentVariable('FUN_STDLIB_DIR', $null, 'User')
  }
}

$userFunCc = [Environment]::GetEnvironmentVariable('FUN_CC', 'User')
if ($null -ne $userFunCc) {
  $uc = $userFunCc.Trim('"')
  if ($uc -eq 'cl /nologo /Fe{out} {src}' -or $uc -eq 'zig') {
    [Environment]::SetEnvironmentVariable('FUN_CC', $null, 'User')
  }
}

$userFunCcArgs = [Environment]::GetEnvironmentVariable('FUN_CC_ARGS', 'User')
if ($null -ne $userFunCcArgs) {
  $ua = $userFunCcArgs.Trim('"')
  if ($ua -eq '' -or $ua -eq 'cc') {
    [Environment]::SetEnvironmentVariable('FUN_CC_ARGS', $null, 'User')
  }
}

Write-Host "Uninstalled fun from: $destPrefix"
