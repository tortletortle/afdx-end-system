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

# TX chain dependencies are now elaborated inside AFDX_top, not only the T04 TB.
$txmods = @(
  'rtl/tx/tx_sn_gen.v', 'rtl/tx/tx_port_buf.v', 'rtl/tx/tx_frame_builder.v',
  'rtl/tx/tx_vl_scheduler.v', 'rtl/tx/tx_rm.v', 'rtl/tx/tx_pace.v',
  'rtl/tx/mac_tx_if.v'
)
$rxmods = @('rtl/rx/mac_rx_if.v', 'rtl/rx/rx_block_pool.v',
            'rtl/rx/rx_pmem_queue.v', 'rtl/rx/rx_vl_lookup.v',
            'rtl/rx/rx_flt.v', 'rtl/rx/rx_ic.v', 'rtl/rx/rx_rm.v',
            'rtl/rx/rx_ip_udp_parse.v', 'rtl/rx/rx_port_buf.v',
            'rtl/mgmt/mgmt_sap_rx.v',
            'rtl/top/stats_regs.v', 'rtl/mgmt/snmp_lite.v',
            'rtl/mgmt/a615a_tftp.v', 'rtl/mgmt/rtc_sync.v')
# continue4: the management plane and the global statistics page are now
# elaborated inside AFDX_top, so they join $rxmods and every gate-1/gate-3
# target picks them up automatically. NOTE: never put a comment line *inside*
# a PowerShell array literal - the element line right after it is swallowed.
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads BOM-less
# scripts as ANSI/GBK and non-ASCII comments break the parser.
# gate 1: top elaboration
Lint 'AFDX_top' ($base + @('--top-module','AFDX_top') + $common + $txmods + $rxmods + @('rtl/top/init_sweep.v','rtl/top/AFDX_top.v'))

# gate 2: standalone common modules (not yet instantiated in AFDX_top)
# rst_sync is excluded: its output port is named like the module itself
# (legal Verilog, existing code), and Verilator refuses a --top-module
# whose signals collide with the module name ("same name as instance").
# It stays covered by the AFDX_top gate.
foreach ($m in @(
  @('bram_sdp',  'rtl/common/bram_sdp.v'),
  @('init_sweep', 'rtl/top/init_sweep.v'),
  @('sync_fifo', 'rtl/common/sync_fifo.v'),
  @('crc32',     'rtl/common/crc32.v'),
  @('timebase',  'rtl/common/timebase.v'),
  @('tx_sn_gen',   'rtl/tx/tx_sn_gen.v'),
  @('tx_port_buf', 'rtl/tx/tx_port_buf.v'),
  @('tx_frame_builder', 'rtl/tx/tx_frame_builder.v'),
  @('tx_pace',         'rtl/tx/tx_pace.v'),
  @('tx_rm',           'rtl/tx/tx_rm.v'),
  @('tx_vl_scheduler', 'rtl/tx/tx_vl_scheduler.v'),
  @('mac_tx_if',       'rtl/tx/mac_tx_if.v', 'rtl/common/crc32.v'),
  @('mac_rx_if',       'rtl/rx/mac_rx_if.v'),
  @('rx_ic',           'rtl/rx/rx_ic.v'),
  @('rx_rm',           'rtl/rx/rx_rm.v'),
  @('rx_ip_udp_parse', 'rtl/rx/rx_ip_udp_parse.v'),
  @('rx_port_buf',     'rtl/rx/rx_port_buf.v'),
  @('rx_flt',          'rtl/rx/rx_flt.v'),
  @('rx_vl_lookup',    'rtl/rx/rx_vl_lookup.v'),
  @('mgmt_sap_rx',     'rtl/mgmt/mgmt_sap_rx.v'),
  @('stats_regs',      'rtl/top/stats_regs.v'),
  @('snmp_lite',       'rtl/mgmt/snmp_lite.v'),
  @('a615a_tftp',      'rtl/mgmt/a615a_tftp.v'),
  @('rtc_sync',        'rtl/mgmt/rtc_sync.v')
)) {
  Lint $m[0] ($base + @('--top-module', $m[0]) + @($m[1..($m.Count-1)]))
}

# gate 3: TBs
$tbbase = $base + @('--timing','-Wno-PINCONNECTEMPTY')
Lint 'tb_t00_common' ($tbbase + @('--top-module','tb_t00_common') + @(
  'rtl/common/crc32.v','rtl/common/sync_fifo.v','rtl/common/bram_sdp.v',
  'sim/tb/tb_t00_common.v'))
Lint 'tb_t01_reset_regs' ($tbbase + @('--top-module','tb_t01_reset_regs') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t01_reset_regs.v'))
Lint 'tb_t02_tx_buf_sn' ($tbbase + @('--top-module','tb_t02_tx_buf_sn') + @(
  'rtl/tx/tx_sn_gen.v','rtl/tx/tx_port_buf.v','sim/tb/tb_t02_tx_buf_sn.v'))
$txchain = @('rtl/common/timebase.v','rtl/common/crc32.v','rtl/common/bram_sdp.v',
  'rtl/tx/tx_sn_gen.v','rtl/tx/tx_port_buf.v','rtl/tx/tx_frame_builder.v',
  'rtl/tx/tx_vl_scheduler.v','rtl/tx/tx_rm.v','rtl/tx/tx_pace.v','rtl/tx/mac_tx_if.v',
  'sim/tb/tb_t04_tx_chain.v')
Lint 'tb_t04_tx_chain'  ($tbbase + @('--top-module','tb_t04_tx_chain')  + $txchain)
Lint 'tb_t04g_tx_chain' ($tbbase + @('--top-module','tb_t04g_tx_chain') + $txchain)
Lint 'tb_t03_frame_builder' ($tbbase + @('--top-module','tb_t03_frame_builder') + @(
  'rtl/common/bram_sdp.v','rtl/tx/tx_sn_gen.v','rtl/tx/tx_frame_builder.v','sim/tb/tb_t03_frame_builder.v'))
Lint 'tb_t22a_frontdoor_tx' ($tbbase + @('--top-module','tb_t22a_frontdoor_tx') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t22a_frontdoor_tx.v'))
Lint 'tb_t05c_cfg_budget' ($tbbase + @('--top-module','tb_t05c_cfg_budget') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t05c_cfg_budget.v'))

Lint 'tb_t08a_rx_ingress' ($tbbase + @('--top-module','tb_t08a_rx_ingress') + @(
  'rtl/rx/mac_rx_if.v','sim/tb/tb_t08a_rx_ingress.v'))
Lint 'tb_t08ag_rx_ingress' ($tbbase + @('--top-module','tb_t08ag_rx_ingress') + @(
  'rtl/rx/mac_rx_if.v','sim/tb/tb_t08a_rx_ingress.v'))
Lint 'tb_t08b_top_rx' ($tbbase + @('--top-module','tb_t08b_top_rx') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08b_top_rx.v'))
Lint 'tb_t08bg_top_rx' ($tbbase + @('--top-module','tb_t08bg_top_rx') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08b_top_rx.v'))
Lint 'tb_t08c_host_arb' ($tbbase + @('--top-module','tb_t08c_host_arb') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08c_host_arb.v'))
Lint 'tb_t08cg_host_arb' ($tbbase + @('--top-module','tb_t08cg_host_arb') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08c_host_arb.v'))
Lint 'tb_t08d_top_flt' ($tbbase + @('--top-module','tb_t08d_top_flt') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08d_top_flt.v'))
Lint 'tb_t08dg_top_flt' ($tbbase + @('--top-module','tb_t08dg_top_flt') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08d_top_flt.v'))
Lint 'tb_t08e_top_ic' ($tbbase + @('--top-module','tb_t08e_top_ic') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08e_top_ic.v'))
Lint 'tb_t08eg_top_ic' ($tbbase + @('--top-module','tb_t08eg_top_ic') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t08e_top_ic.v'))
Lint 'tb_t10_top_rm' ($tbbase + @('--top-module','tb_t10_top_rm') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t10_top_rm.v'))
Lint 'tb_t10g_top_rm' ($tbbase + @('--top-module','tb_t10g_top_rm') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t10_top_rm.v'))
Lint 'tb_t11_top_port' ($tbbase + @('--top-module','tb_t11_top_port') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t11_top_port.v'))
Lint 'tb_t11g_top_port' ($tbbase + @('--top-module','tb_t11g_top_port') + $common + $txmods + $rxmods + @(
  'rtl/top/init_sweep.v','rtl/top/AFDX_top.v','sim/tb/tb_t11_top_port.v'))
Lint 'tb_t09_rx_ic' ($tbbase + @('--top-module','tb_t09_rx_ic') + @(
  'rtl/rx/rx_ic.v','sim/tb/tb_t09_rx_ic.v'))
Lint 'tb_t09s_rx_ic' ($tbbase + @('--top-module','tb_t09s_rx_ic') + @(
  'rtl/rx/rx_ic.v','sim/tb/tb_t09_rx_ic.v'))
Lint 'tb_t09p_rx_ic' ($tbbase + @('--top-module','tb_t09p_rx_ic') + @(
  'rtl/rx/rx_ic.v','sim/tb/tb_t09p_rx_ic.v'))
Lint 'tb_t09ps_rx_ic' ($tbbase + @('--top-module','tb_t09ps_rx_ic') + @(
  'rtl/rx/rx_ic.v','sim/tb/tb_t09p_rx_ic.v'))
Lint 'tb_t12c_lookup' ($tbbase + @('--top-module','tb_t12c_lookup') + @(
  'rtl/rx/rx_vl_lookup.v','sim/tb/tb_t12_rx_lookup.v'))
Lint 'tb_t12r_lookup' ($tbbase + @('--top-module','tb_t12r_lookup') + @(
  'rtl/rx/rx_vl_lookup.v','sim/tb/tb_t12_rx_lookup.v'))
Lint 'tb_t12s_lookup' ($tbbase + @('--top-module','tb_t12s_lookup') + @(
  'rtl/rx/rx_vl_lookup.v','sim/tb/tb_t12_rx_lookup.v'))
Lint 'tb_t12h_lookup' ($tbbase + @('--top-module','tb_t12h_lookup') + @(
  'rtl/rx/rx_vl_lookup.v','sim/tb/tb_t12_rx_lookup.v'))
Lint 'tb_t12f_top_lookup' ($tbbase + @('--top-module','tb_t12f_top_lookup') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t12f_top_lookup.v'))
Lint 'tb_t12fg_top_lookup' ($tbbase + @('--top-module','tb_t12fg_top_lookup') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t12f_top_lookup.v'))
Lint 'tb_t22_top_loopback' ($tbbase + @('--top-module','tb_t22_top_loopback') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t22_top_loopback.v'))
Lint 'tb_t22g_top_loopback' ($tbbase + @('--top-module','tb_t22g_top_loopback') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t22_top_loopback.v'))
Lint 'tb_t11i_top_int' ($tbbase + @('--top-module','tb_t11i_top_int') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t11i_top_int.v'))
Lint 'tb_t11ig_top_int' ($tbbase + @('--top-module','tb_t11ig_top_int') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t11i_top_int.v'))

# continue4: three new management-plane cases
#   T14 global statistics page, T15 snmp_lite, T16 a615a_tftp + rtc_sync
Lint 'tb_t14_stats_regs' ($tbbase + @('--top-module','tb_t14_stats_regs') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t14_stats_regs.v'))
Lint 'tb_t15_snmp' ($tbbase + @('--top-module','tb_t15_snmp') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t15_snmp.v'))
Lint 'tb_t16_tftp_rtc' ($tbbase + @('--top-module','tb_t16_tftp_rtc') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t16_tftp_rtc.v'))

# test-set completion 20260928: worst-case latency, RTC drift, 615A unload
Lint 'tb_t13w_worst' ($tbbase + @('--top-module','tb_t13w_worst') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t13w_worst.v'))
Lint 'tb_t13wg_worst' ($tbbase + @('--top-module','tb_t13wg_worst') +
  $common + $txmods + $rxmods + @('rtl/top/init_sweep.v',
  'rtl/top/AFDX_top.v','sim/tb/tb_t13w_worst.v'))
Lint 'tb_t16a_rtc_drift' ($tbbase + @('--top-module','tb_t16a_rtc_drift') + @(
  'rtl/mgmt/rtc_sync.v','sim/tb/tb_t16a_rtc_drift.v'))
Lint 'tb_t16u_tftp_unload' ($tbbase + @('--top-module','tb_t16u_tftp_unload') + @(
  'rtl/mgmt/a615a_tftp.v','sim/tb/tb_t16u_tftp_unload.v'))

Remove-Item $gatefile -Force -ErrorAction SilentlyContinue
if ($script:fail -ne 0) { Write-Output "LINT GATE: FAIL"; exit 1 }
Write-Output "LINT GATE: PASS (all gates 0 %Error)"
exit 0
