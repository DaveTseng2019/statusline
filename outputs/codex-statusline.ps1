# ~\.claude\scripts\codex-statusline.ps1
# Called by statusline-command.ps1. Prints one plain-text line (no ANSI) with the
# Codex/ChatGPT quota, or nothing at all when there is no data yet.
#
# Two modes:
#   (no args)  status mode  - read the cache file and print it. Must be fast.
#                             Fires a background refresh when the cache is stale.
#   -Refresh   refresh mode - actually call codex-reset-checker --json and write the cache.
#
# ASCII-only source on purpose: this file has no BOM, so Chinese comments here would be
# decoded as CP950 by Windows PowerShell 5.1 and break the parser.

param([switch]$Refresh)

$cache = Join-Path $env:TEMP 'codex-quota.txt'
$lock  = Join-Path $env:TEMP 'codex-quota.lock'
$TTL   = 600   # seconds before the cache counts as stale
$SPAWN = 120   # minimum seconds between two background refreshes

# notes: the cache holds only the short rendered string, never the raw --json output.
#        That output carries email and account_id; there is no reason to drop it in %TEMP%.
#        To add a field, read it in the Refresh block below - do not cache the whole payload.

if ($Refresh) {
  $line = 'codex ?'
  try {
    $out = & codex-reset-checker --json 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
      $j = $out | ConvertFrom-Json
      $w = $j.usage.primary_window
      if ($w) {
        $pct = [int][double]$w.used_percent
        $line = "codex $pct%"
        if ($w.reset_at) {
          $r = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$w.reset_at).ToLocalTime()
          $line = $line + ' ' + [char]0x2192 + $r.ToString('M/d')
        }
      }
      $rc = [int]$j.available_count
      if ($rc -gt 0) {
        $line = $line + " rc:$rc"
      }
    }
  } catch {}
  try { [IO.File]::WriteAllText($cache, $line, [Text.UTF8Encoding]::new($false)) } catch {}
  return
}

# --- status mode ---
$fresh = $false
if (Test-Path $cache) {
  $age = ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalSeconds
  if ($age -lt $TTL) {
    $fresh = $true
  }
}

if (-not $fresh) {
  # Throttle with the lock file's LastWriteTime. Real mutual exclusion is not needed here.
  $spawn = $true
  if (Test-Path $lock) {
    $lockAge = ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalSeconds
    if ($lockAge -lt $SPAWN) {
      $spawn = $false
    }
  }
  if ($spawn) {
    try {
      [IO.File]::WriteAllText($lock, '')
      $self = $PSCommandPath
      $psargs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $self, '-Refresh')
      Start-Process -FilePath 'pwsh.exe' -WindowStyle Hidden -ArgumentList $psargs -ErrorAction SilentlyContinue | Out-Null
    } catch {}
  }
}

# Print a stale cache too, marked with a trailing ~ so a hung refresh is visible.
if (Test-Path $cache) {
  try {
    $txt = [IO.File]::ReadAllText($cache).Trim()
    if ($txt) {
      if (-not $fresh) {
        $txt = $txt + ' ~'
      }
      Write-Output $txt
    }
  } catch {}
}
