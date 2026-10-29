# Shared simulator lock for Questa FSE / ModelSim single-seat hosts.
# Usage:
#   powershell -File tools\sim_lock.ps1 -Action acquire -Owner replay_098efc9
#   powershell -File tools\sim_lock.ps1 -Action release -Owner replay_098efc9
#   powershell -File tools\sim_lock.ps1 -Action status
# Lock file: out/.sim_lock (owner, pid, started_local). Dead PID = stale, cleared.
# ASCII-only. Does not kill foreign vsim sessions.
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('acquire', 'release', 'status')]
  [string]$Action,
  [string]$Owner = '',
  [int]$WaitSeconds = 0,
  [string]$LockPath = ''
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
if (-not $LockPath) { $LockPath = Join-Path $root 'out\.sim_lock' }
$outDir = Split-Path $LockPath -Parent
if (-not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

function Read-Lock {
  if (-not (Test-Path -LiteralPath $LockPath)) { return $null }
  $raw = Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Write-Lock([string]$own, [int]$pidVal) {
  $obj = [ordered]@{
    owner = $own
    pid = $pidVal
    started_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    host = $env:COMPUTERNAME
  }
  ($obj | ConvertTo-Json) | Set-Content -LiteralPath $LockPath -Encoding ASCII
}

function Test-PidAlive([int]$pidVal) {
  if ($pidVal -le 0) { return $false }
  $p = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
  return [bool]$p
}

function Clear-Stale {
  $lk = Read-Lock
  if (-not $lk) { return $false }
  if (-not (Test-PidAlive ([int]$lk.pid))) {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    Write-Output ("STALE_CLEARED owner=" + $lk.owner + " dead_pid=" + $lk.pid)
    return $true
  }
  return $false
}

function Get-VsimBusy {
  return @(Get-CimInstance Win32_Process -Filter "Name='vsim.exe' OR Name='vsimk.exe'" -ErrorAction SilentlyContinue)
}

switch ($Action) {
  'status' {
    Clear-Stale | Out-Null
    $lk = Read-Lock
    $busy = Get-VsimBusy
    if ($lk) {
      Write-Output ("LOCK held owner=" + $lk.owner + " pid=" + $lk.pid + " started=" + $lk.started_local)
    } else {
      Write-Output 'LOCK free'
    }
    if ($busy.Count -gt 0) {
      $ids = ($busy | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ', '
      Write-Output ("VSIM_BUSY $ids")
    } else {
      Write-Output 'VSIM_FREE'
    }
    exit 0
  }
  'release' {
    if (-not $Owner) { Write-Output 'ERROR: -Owner required for release'; exit 1 }
    $lk = Read-Lock
    if (-not $lk) { Write-Output 'LOCK already free'; exit 0 }
    if ($lk.owner -ne $Owner -and [int]$lk.pid -ne $PID) {
      Write-Output ("ERROR: lock owned by " + $lk.owner + " pid=" + $lk.pid + "; refusing release as " + $Owner)
      exit 2
    }
    Remove-Item -LiteralPath $LockPath -Force
    Write-Output ("LOCK released owner=" + $Owner)
    exit 0
  }
  'acquire' {
    if (-not $Owner) { Write-Output 'ERROR: -Owner required for acquire'; exit 1 }
    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSeconds))
    while ($true) {
      Clear-Stale | Out-Null
      $lk = Read-Lock
      if ($lk -and [int]$lk.pid -eq $PID -and $lk.owner -eq $Owner) {
        Write-Output ("LOCK already held by self owner=" + $Owner)
        exit 0
      }
      $busy = Get-VsimBusy
      if (-not $lk -and $busy.Count -eq 0) {
        Write-Lock $Owner $PID
        $check = Read-Lock
        if ($check -and $check.owner -eq $Owner -and [int]$check.pid -eq $PID) {
          Write-Output ("LOCK acquired owner=" + $Owner + " pid=" + $PID)
          exit 0
        }
        # lost race; retry
      } else {
        $why = @()
        if ($lk) { $why += ("lock owner=" + $lk.owner + " pid=" + $lk.pid) }
        if ($busy.Count -gt 0) {
          $ids = ($busy | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ','
          $why += ("vsim=$ids")
        }
        $msg = 'LICENSE_BUSY ' + ($why -join '; ')
        if ((Get-Date) -ge $deadline) {
          Write-Output ("ERROR: $msg")
          Write-Output 'REFUSE acquire. Wait or release stale owner; do not kill foreign sessions.'
          exit 2
        }
        Write-Output ("WAIT $msg")
        Start-Sleep -Seconds 5
      }
    }
  }
}
