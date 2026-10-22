# =====================================================================
# tools_lint.ps1 - Verilator lint gate
# Gate 1 file list is READ from elinx/AFDX_top_sources.f (keeps lint current).
# Gate 2: each production module from sources.f as --top-module (where legal).
# Gate 3: representative TBs (unchanged set; not a full manifest sweep).
# Verilator 5.006: -Wno-fatal; only %Error fails a gate.
# PITFALL: bare filenames via -f response file in repo root (path args break).
# ASCII-only (PS 5.1 + non-ASCII comments break param parsing).
# =====================================================================
$ver = "C:\Program Files (x86)\eHiWay\eLinx3.0\verilator\verilator.exe"
if (-not (Test-Path $ver)) { Write-Output ("ERROR: verilator not found: " + $ver); exit 1 }
$root = $PSScriptRoot
Set-Location $root

$script:fail = 0
$gatefile = '_lint_gate.f'
function Lint {
  param([string]$Name, [string[]]$VArgs)
  Set-Content -Path $gatefile -Value $VArgs
  Write-Output ("== lint " + $Name)
  & $ver '-f' $gatefile 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("LINT-FAIL: " + $Name)
    $script:fail = 1
  } else {
    Write-Output ("LINT-OK:   " + $Name)
  }
}

function Read-SourcesF {
  param([string]$Path)
  $list = @()
  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith('//')) { return }
    $list += ($line -replace '\\', '/')
  }
  return $list
}

$sourcesF = Join-Path $root 'elinx\AFDX_top_sources.f'
if (-not (Test-Path -LiteralPath $sourcesF)) {
  Write-Output ("ERROR: missing " + $sourcesF); exit 1
}
$prod = @(Read-SourcesF $sourcesF)
if ($prod.Count -lt 10) { Write-Output ("ERROR: sources.f too short: " + $prod.Count); exit 1 }
Write-Output ("sources.f modules=" + $prod.Count)

# -Wno-BLKLOOPINIT: Verilator flags reset for-loops that assign memories with
# blocking (=) inside an always @(posedge) that also uses <= elsewhere. Quartus
# prefers blocking init in that pattern; flipping to <= trips 10110 risk the
# other way. Exempt here; see lint_triage.md "BLKLOOPINIT exemption".
$base = @('--lint-only', '-Wall', '-Wno-fatal', '-Wno-WIDTH', '-Wno-BLKLOOPINIT')

# gate 1: top elaboration from sources.f (order preserved)
Lint 'AFDX_top' ($base + @('--top-module', 'AFDX_top') + $prod)

# gate 2: each reachable module as --top-module with full sources.f (resolves subs)
$skipStandalone = @('rtl/top/AFDX_top.v', 'rtl/common/rst_sync.v')
foreach ($rel in $prod) {
  if ($skipStandalone -contains $rel) { continue }
  $mod = [IO.Path]::GetFileNameWithoutExtension($rel)
  Lint $mod ($base + @('--top-module', $mod) + $prod)
}

# gate 3: representative TBs (subset; not full manifest)
$tbbase = $base + @('--timing', '-Wno-PINCONNECTEMPTY')
Lint 'tb_t00_common' ($tbbase + @('--top-module', 'tb_t00_common') + @(
  'rtl/common/crc32.v', 'rtl/common/sync_fifo.v', 'rtl/common/bram_sdp.v',
  'sim/tb/tb_t00_common.v'))
# sync_fifo kept for T00 only (not in production sources.f)
Lint 'tb_t01_reset_regs' ($tbbase + @('--top-module', 'tb_t01_reset_regs') + $prod + @(
  'sim/tb/tb_t01_reset_regs.v'))
Lint 'tb_gate_public_loopback' ($tbbase + @('--top-module', 'tb_gate_public_loopback') + $prod + @(
  'sim/tb/tb_gate_public_loopback.v'))

Remove-Item $gatefile -Force -ErrorAction SilentlyContinue
if ($script:fail -ne 0) { Write-Output "LINT GATE: FAIL"; exit 1 }
Write-Output ("LINT GATE: PASS (all gates 0 %Error; sources.f=" + $prod.Count + ")")
exit 0
