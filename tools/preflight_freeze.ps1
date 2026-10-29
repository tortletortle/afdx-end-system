# Pre-flight for the final freeze run (full regress + T88b + synth + pack). Read-only: changes nothing.
# Usage: powershell -File tools\preflight_freeze.ps1 [-BaseCommit 098efc9]
# Exit 0 = no blocker. Exit 1 = at least one BLOCK line. WARN lines need a human decision.
# ASCII-only on purpose (PS 5.1 reads BOM-less UTF-8 as GBK).
param(
  [string]$BaseCommit = '098efc9'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$block = 0
function Block([string]$m) { Write-Output ("BLOCK " + $m); $script:block++ }
function Warn([string]$m)  { Write-Output ("WARN  " + $m) }
function Ok([string]$m)    { Write-Output ("OK    " + $m) }

# 1. core rtl vs base commit (afdx_app_* are new files and excluded)
$core = @(git diff --name-only $BaseCommit -- rtl ':(exclude)rtl/top/afdx_app_*.v' 2>$null)
if ($core.Count -gt 0) { Block ("core rtl differs from " + $BaseCommit + ": " + ($core -join ', ')) }
else { Ok ("core rtl identical to " + $BaseCommit + " (worktree, excluding afdx_app_*)") }
$dirty = @(git status --short -- rtl sim/tb sim/tests.manifest sim/bind_scope.tsv sim/run_regress.ps1 sim/run_smoke.ps1 tools/sim_lock.ps1 2>$null)
if ($dirty.Count -gt 0) { Block ("uncommitted frozen inputs: " + ($dirty -join ' | ')) } else { Ok "rtl, TB, manifest, bind_scope, runners committed" }
Write-Output ("INFO  HEAD " + (git rev-parse --short HEAD) + " on " + (git rev-parse --abbrev-ref HEAD))

# 2. simulator / synthesis exclusivity
$lock = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sim_lock.ps1') -Action status 2>&1
if (($lock -join ' ') -match 'LOCK free') { Ok "sim_lock free" } else { Block ("sim_lock: " + ($lock -join ' ')) }
$busy = @(Get-Process -Name vsim, vsimk, vish, vlog, eLinx_synthesis -ErrorAction SilentlyContinue)
if ($busy.Count -gt 0) { Block ("running: " + (($busy | ForEach-Object { $_.Name + ':' + $_.Id }) -join ', ')) } else { Ok "no vsim / eLinx_synthesis running" }

# 3. Windows Update (pause it from Settings before starting; this script does not touch services)
foreach ($n in 'wuauserv', 'UsoSvc', 'BITS') {
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  if ($s) {
    if ($s.Status -eq 'Running') { Warn ("service " + $n + " is Running: pause Windows Update before the run") }
    else { Ok ("service " + $n + " " + $s.Status) }
  }
}
$pend = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'WindowsUpdate RebootRequired' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS RebootPending' }
if ($pend.Count -gt 0) { Warn ("pending reboot: " + ($pend -join ', ')) } else { Ok "no pending reboot flag" }

# 4. memory, disk, big processes
$os = Get-CimInstance Win32_OperatingSystem
$freeMb = [int]($os.FreePhysicalMemory / 1024)
if ($freeMb -lt 2500) { Warn ("free RAM " + $freeMb + " MB; close programs (32-bit eLinx needs ~2 GB of its own address space, vsim needs more)") } else { Ok ("free RAM " + $freeMb + " MB") }
$drv = Get-PSDrive -Name C
$freeGb = [int]($drv.Free / 1GB)
if ($freeGb -lt 30) { Warn ("free disk C: " + $freeGb + " GB (full regress + pack need tens of GB)") } else { Ok ("free disk C: " + $freeGb + " GB") }
$big = Get-Process | Where-Object { $_.WorkingSet64 -gt 400MB } | Sort-Object WorkingSet64 -Descending | Select-Object -First 8
foreach ($b in $big) { Write-Output ("INFO  big process " + $b.Name + " " + [int]($b.WorkingSet64 / 1MB) + " MB (id " + $b.Id + ")") }

# 5. tool paths
$tools = @(
  'C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe',
  'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe',
  'C:\Program Files\WinRAR\Rar.exe'
)
foreach ($t in $tools) { if (Test-Path -LiteralPath $t) { Ok ("found " + $t) } else { Block ("missing " + $t) } }
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) { Ok "python on PATH" } else { Block "python not on PATH" }

Write-Output ("PREFLIGHT blocks=" + $block)
if ($block -gt 0) { exit 1 }
exit 0
