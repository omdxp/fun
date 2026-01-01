[CmdletBinding()]
param(
  [string]$RepoRoot = "",
  [int]$PerFileTimeoutSec = 120,
  [int]$ProgressEvery = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $scriptDir = if ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
  } elseif ($PSScriptRoot) {
    $PSScriptRoot
  } else {
    (Get-Location).Path
  }

  $RepoRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Get-RelativePath([string]$base, [string]$full) {
  if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full
  }
  return $full.Substring($base.Length).TrimStart('\', '/')
}

function Is-RunnableFile([string]$path) {
  return ((Get-Content -LiteralPath $path -Raw) -match '(?m)^\s*fun\s+main\s*\(')
}

function Is-ExpectedFail([string]$relPath) {
  # Intentional negative examples.
  if ($relPath -ieq 'examples\test_circular.fn') { return $true }

  # Direct files in examples/error_cases are meant to fail.
  if ($relPath -match '^examples\\error_cases\\[^\\]+\.fn$') { return $true }

  # Circular dependency demonstration (each file fails on its own).
  if ($relPath -match '^examples\\error_cases\\circular_dependency\\[^\\]+\.fn$') { return $true }

  # NOTE: Files under examples/error_cases/duplicate_symbols/* are helper modules;
  # they should compile successfully on their own.
  return $false
}

function Quote-WinArg([string]$arg) {
  if ($null -eq $arg) { return '""' }
  if ($arg -notmatch '[\s"]') { return $arg }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $backslashes = 0
  foreach ($ch in $arg.ToCharArray()) {
    if ($ch -eq '\\') {
      $backslashes++
      continue
    }
    if ($ch -eq '"') {
      [void]$sb.Append(('\\' * ($backslashes * 2 + 1)))
      [void]$sb.Append('"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$sb.Append(('\\' * $backslashes))
      $backslashes = 0
    }
    [void]$sb.Append($ch)
  }
  if ($backslashes -gt 0) {
    [void]$sb.Append(('\\' * ($backslashes * 2)))
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-Fun([string]$funExe, [string[]]$argumentList, [string]$workingDir, [int]$timeoutSec) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $funExe
  $psi.WorkingDirectory = $workingDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.Arguments = (($argumentList | ForEach-Object { Quote-WinArg $_ }) -join ' ')

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  [void]$p.Start()

  $timeoutMs = [Math]::Max(1, $timeoutSec) * 1000
  if (-not $p.WaitForExit($timeoutMs)) {
    try { $p.Kill() } catch {}
    return [pscustomobject]@{ ExitCode = 124; Stdout = ''; Stderr = "Timed out after ${timeoutSec}s" }
  }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Stdout   = $stdout
    Stderr   = $stderr
  }
}

Set-Location -LiteralPath $RepoRoot

$funExe = Join-Path $RepoRoot 'zig-out\bin\fun.exe'
if (-not (Test-Path -LiteralPath $funExe)) {
  throw "Missing $funExe. Run 'zig build' first."
}

# Minimal output assertions (only where we have stable strings).
$expected = @{
  'examples\test.fn' = @('The factorial of')
  'examples\advanced\custom_functions.fn' = @('The result of subtracting')
  'examples\advanced\fit_exhaustive_ok.fn' = @('x was true')
  'examples\advanced\fit_exhaustive_warning.fn' = @('x was true')
  'examples\advanced\for_loops.fn' = @('arr[0]=1', 'arr[2]=3')
  'examples\imports\main.fn' = @('grand_child', 'child')
}

$files = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'examples') -Recurse -Filter *.fn | Sort-Object FullName
$failed = New-Object System.Collections.Generic.List[string]
$unexpectedPass = New-Object System.Collections.Generic.List[string]
$expectedFailCount = 0

Write-Host "Running $($files.Count) example files..."

$idx = 0
foreach ($f in $files) {
  $idx++
  if ($ProgressEvery -gt 0 -and ($idx % $ProgressEvery) -eq 0) {
    Write-Host "... $idx/$($files.Count)" 
  }
  $rel = Get-RelativePath -base $RepoRoot -full $f.FullName
  $rel = $rel -replace '/', '\\'

  $isExpectedFail = Is-ExpectedFail -relPath $rel
  $isRunnable = (Is-RunnableFile -path $f.FullName) -and (-not $isExpectedFail)

  $funArgs = @('-in', $f.FullName)
  if ($isExpectedFail -or (-not $isRunnable)) {
    $funArgs += '-no-exec'
  }

  $res = Invoke-Fun -funExe $funExe -argumentList $funArgs -workingDir $RepoRoot -timeoutSec $PerFileTimeoutSec
  $allOut = ($res.Stdout + "`n" + $res.Stderr)

  if ($isExpectedFail) {
    if ($res.ExitCode -eq 0) {
      $unexpectedPass.Add($rel)
    } else {
      $expectedFailCount++
    }
    continue
  }

  if ($res.ExitCode -ne 0) {
    $failed.Add("$rel (exit=$($res.ExitCode))")
    continue
  }

  if ($expected.ContainsKey($rel)) {
    foreach ($needle in $expected[$rel]) {
      if ($allOut -notmatch [regex]::Escape($needle)) {
        $failed.Add("$rel (missing: $needle)")
        break
      }
    }
  }
}

Write-Host "Total: $($files.Count)  Failed: $($failed.Count)  ExpectedFail: $expectedFailCount  UnexpectedPass: $($unexpectedPass.Count)"

if ($failed.Count -gt 0) {
  Write-Host "\nFailures:" 
  $failed | Sort-Object -Unique | ForEach-Object { Write-Host "FAIL: $_" }
}

if ($unexpectedPass.Count -gt 0) {
  Write-Host "\nUnexpected passes (negative examples returned exit 0):"
  $unexpectedPass | Sort-Object -Unique | ForEach-Object { Write-Host "UNEXPECTED PASS: $_" }
}

if ($failed.Count -gt 0 -or $unexpectedPass.Count -gt 0) {
  exit 1
}

exit 0
