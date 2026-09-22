# =====================================================================
# lint.ps1 - Verilator lint gate (week-1 "three gates", lint leg)
# Usage:  powershell -ExecutionPolicy Bypass -File tools\lint.ps1
# Gates:
#   1) AFDX_top + all common RTL (same flags as week-0 record sec.4)
#   2) each self-contained common module standalone (deep-lints modules
#      not yet instantiated in the top, e.g. bram_sdp before week 3/4)
#   3) each TB (adds --timing -Wno-PINCONNECTEMPTY, week-0 record sec.4)
# Verilator 5.006: WIDTH is the new spelling (WIDTHEXPAND/TRUNC are gone),
# -Wno-fatal keeps warnings non-fatal; only %Error fails a gate.
# PITFALL (2026-09-22, eHiWay Verilator 5.006 / msys-2.0.dll): any file
# argument carrying a path prefix (.\x.v, rtl\x.v, C:\x.v) is mis-parsed
# as a MODULE NAME and triggers "Cannot find file containing module" /
# "-I<dir>" errors; only bare filenames in the current directory work.
# Workaround: pass ALL arguments through a -f response file placed in the
# repo root (its content is not argument-converted; forward slashes OK).
# So the week-0 record sec.4 command line needs this fix when reused.
# Exit 0 iff every gate exits 0. ASCII-only (week-0 pitfall #3).
# =====================================================================
$ver = "C:\Program Files (x86)\eHiWay\eLinx3.0\verilator\verilator.exe"
if (-not (Test-Path $ver)) { Write-Output ("ERROR: verilator not found: " + $ver); exit 1 }
# 平铺布局: 本脚本在仓库根（tools_lint.ps1，与 tools_*.py 同级）。
# 若迁移到 tools/ 目录布局（tools_run_all.py 提示的正式布局），
# 改回: $root = Split-Path -Parent $PSScriptRoot
$root = $PSScriptRoot
Set-Location $root

$script:fail = 0
$gatefile = '_lint_gate.f'   # must be a bare name in cwd (see PITFALL)
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

$common = @(
  'rtl/common/rst_sync.v', 'rtl/common/timebase.v',
  'rtl/common/sync_fifo.v', 'rtl/common/crc32.v',
  'rtl/common/bram_sdp.v'
)
$base = @('--lint-only','-Wall','-Wno-fatal','-Wno-WIDTH')

# gate 1: top elaboration
Lint 'AFDX_top' ($base + @('--top-module','AFDX_top') + $common + @('rtl/top/AFDX_top.v'))

# gate 2: standalone common modules (not yet instantiated in AFDX_top)
# rst_sync is excluded: its output port is named like the module itself
# (legal Verilog, existing code), and Verilator refuses a --top-module
# whose signals collide with the module name ("same name as instance").
# It stays covered by the AFDX_top gate.
foreach ($m in @(
  @('bram_sdp',  'rtl/common/bram_sdp.v'),
  @('sync_fifo', 'rtl/common/sync_fifo.v'),
  @('crc32',     'rtl/common/crc32.v'),
  @('timebase',  'rtl/common/timebase.v'),
  @('tx_sn_gen',   'rtl/tx/tx_sn_gen.v'),
  @('tx_port_buf', 'rtl/tx/tx_port_buf.v')
)) {
  Lint $m[0] ($base + @('--top-module', $m[0]) + @($m[1]))
}

# gate 3: TBs
$tbbase = $base + @('--timing','-Wno-PINCONNECTEMPTY')
Lint 'tb_t00_common' ($tbbase + @('--top-module','tb_t00_common') + @(
  'rtl/common/crc32.v','rtl/common/sync_fifo.v','rtl/common/bram_sdp.v',
  'sim/tb/tb_t00_common.v'))
Lint 'tb_t01_reset_regs' ($tbbase + @('--top-module','tb_t01_reset_regs') + $common + @(
  'rtl/top/AFDX_top.v','sim/tb/tb_t01_reset_regs.v'))
Lint 'tb_t02_tx_buf_sn' ($tbbase + @('--top-module','tb_t02_tx_buf_sn') + @(
  'rtl/tx/tx_sn_gen.v','rtl/tx/tx_port_buf.v','sim/tb/tb_t02_tx_buf_sn.v'))

Remove-Item $gatefile -Force -ErrorAction SilentlyContinue
if ($script:fail -ne 0) { Write-Output "LINT GATE: FAIL"; exit 1 }
Write-Output "LINT GATE: PASS (all gates 0 %Error)"
exit 0
