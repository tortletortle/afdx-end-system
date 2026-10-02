# =====================================================================
# run_regress.ps1 - regression runner (design doc 12.4, week-1 skeleton)
# Usage (from sim/):  powershell -ExecutionPolicy Bypass -File .\run_regress.ps1
#   optional:  -Tests T00,T01   (subset)   -KeepWork  (skip recompile)
#              -OutDir out/neg_t13  (logs + CSV go there; default out)
#              -PlusArgs '+T13_TOTAL_MAX_US=5'  (passed to every vsim)
# Verdict: strict, see regress_verdict.ps1 (audit 20260928 A04) - one
# verdict line per test, no FAIL/Error text, clean simulator summary.
# Reads tests.manifest, compiles once, runs each TB in its own vsim
# session (600 s cap per test), writes out/regress.csv and per-test logs
# out/<id>_console.txt. Exit 0 only if every test PASSes.
# NOTE (week0 pitfall #5): whole-regression wall time can exceed the
# MCP-bridge ~120 s foreground limit - launch detached and poll the log:
#   Start-Process powershell -ArgumentList '-ExecutionPolicy','Bypass',
#     '-File','C:\Workspace\diansai\sim\run_regress.ps1' ...
# ASCII-only on purpose (week0 pitfall #3: PS 5.1 parses BOM-less UTF-8
# .ps1 as GBK, stray bytes can silently break script behaviour).
# =====================================================================
param(
  [string[]]$Tests = @(),
  [switch]$KeepWork,
  [switch]$Acc          # pass -voptargs=+acc so $dumpvars VCDs have
                        # content (week-0 pitfall #11); costs sim time
  ,[switch]$Coverage    # compile +cover=sb and save one UCDB per test
  ,[string]$OutDir = 'out'   # per-run output dir (relative to sim/)
  ,[string]$PlusArgs = ''    # e.g. '+T13_TOTAL_MAX_US=5' for negative runs
)
$ErrorActionPreference = 'Stop'

# --- locate vsim (same candidate list as run_t01.ps1) ---
$cands = @(
  "C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"
)
$vsim = $null
foreach ($c in $cands) { if (Test-Path $c) { $vsim = $c; break } }
if (-not $vsim) {
  $f = Get-ChildItem "C:\altera_pro" -Recurse -Filter "vsim.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { $vsim = $f.FullName }
}
if (-not $vsim) { Write-Output "ERROR: vsim.exe not found"; exit 1 }

# --- license env (Starter SALT keyring, see run_t01.ps1) ---
$licUser = [Environment]::GetEnvironmentVariable('SALT_LICENSE_SERVER','User')
if (-not $env:SALT_LICENSE_SERVER -and $licUser) { $env:SALT_LICENSE_SERVER = $licUser }
if (-not $env:SALT_LICENSE_SERVER) { Write-Output "ERROR: SALT_LICENSE_SERVER not set"; exit 1 }

# --- kill leftovers from a previous killed run (week0 pitfall #5) ---
foreach ($pn in @('vsim','vish','vlm','vlog','vcom','vopt')) {
  Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$sim = $PSScriptRoot
Set-Location $sim
. (Join-Path $sim 'regress_verdict.ps1')
$OutDir = $OutDir.TrimEnd('/', '\')
if ($OutDir -eq '' -or $OutDir -match '[\s"&|<>]') { Write-Output "ERROR: bad -OutDir '$OutDir'"; exit 1 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if ($PlusArgs -ne '') { $env:VSIM_PLUSARGS = $PlusArgs } else { Remove-Item Env:VSIM_PLUSARGS -ErrorAction SilentlyContinue }
$coverageRoot = Join-Path (Split-Path -Parent $sim) 'out/arena-debug/continue5/ucdb'
if ($Coverage) {
  New-Item -ItemType Directory -Force -Path $coverageRoot | Out-Null
  $env:VLOG_COVERAGE = '1'
} else {
  $env:VLOG_COVERAGE = '0'
  Remove-Item Env:UCDB_OUT -ErrorAction SilentlyContinue
}

# --- manifest ---
$manifest = @()
foreach ($line in (Get-Content (Join-Path $sim 'tests.manifest') -Encoding UTF8)) {
  $t = "$line".Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $p = $t -split '\s+'
  $cfg = if ($p.Count -gt 2) { $p[2] } else { 'default' }
  $manifest += [pscustomobject]@{ Id = $p[0]; Tb = $p[1]; Cfg = $cfg }
}
$dupIds = @($manifest | Group-Object Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupIds.Count -gt 0) { Write-Output ("ERROR: duplicate test id(s) in manifest: " + ($dupIds -join ',')); exit 1 }
# powershell -File passes "-Tests T00,T01" as one string (not a string[]).
# Accept both that documented spelling and -Command's array spelling.
if ($Tests.Count -gt 0) {
  $selected = @($Tests | ForEach-Object { $_ -split ',' } |
                ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  $unknown = @($selected | Where-Object { @($manifest.Id) -notcontains $_ })
  if ($unknown.Count -gt 0) { Write-Output ("ERROR: unknown test id(s): " + ($unknown -join ',')); exit 1 }
  $manifest = @($manifest | Where-Object { $selected -contains $_.Id })
}
if ($manifest.Count -eq 0) { Write-Output "ERROR: no tests selected"; exit 1 }
if (@($manifest | Where-Object { $_.Id -eq 'T09' -or $_.Id -eq 'T09s' }).Count -gt 0) {
  # Generate the oracle before any T09 session; a failed model is a failed run.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t09_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T09 Python golden vector generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T15*' -or $_.Id -like 'T16*' }).Count -gt 0) {
  # continue4: T15/T16 use their own SAP golden frames carrying real SNMP BER
  # PDUs and ARINC-615A TFTP packets (same afdx_model + zlib wire-order FCS).
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t15_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T15/T16 management golden vector generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T08*' -or $_.Id -like 'T11*' -or $_.Id -like 'T14*' -or $_.Id -like 'T15*' -or $_.Id -like 'T16*' -or $_.Id -like 'T17*' -or $_.Id -like 'T21*' -or $_.Id -like 'T22*' -or $_.Id -like 'T23*' }).Count -gt 0) {
  # T08/T11/T14/T15/T16/T17/T21/T22/T23 share independently FCS-checked real-frame golden vectors.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t08a_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T08 RX Python golden vector generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T12*' -or $_.Id -like 'T08f*' }).Count -gt 0) {
  # T12 and T08f need both tables and independent key lists; offline rejection
  # must fail the regression instead of running against an old partial image.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t12_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T12 offline hash image generation failed"
    exit 1
  }
}
if ($Acc) { $env:VSIM_ACC = '1' } else { $env:VSIM_ACC = '0' }

# --- vsim batch helper: cmd-level redirect (byte-transparent, pitfall #4),
#     detached so the 600 s cap is enforced by us, not the bridge ---
function Run-Vsim {
  param([string]$Do, [string]$Log, [int]$TimeoutSec = 600)
  Remove-Item $Log -Force -ErrorAction SilentlyContinue
  # cmd /c quote-stripping pitfall: with several quotes in the string,
  # cmd strips the FIRST and LAST quote and breaks the exe path.
  # Wrapping the whole tail in an extra outer quote pair preserves them.
  # Start-Process -PassThru on PS 5.1 can leave ExitCode null even after
  # WaitForExit; use System.Diagnostics.Process directly instead.
  $cmdline = '/c ""' + $vsim + '" -c -do "' + $Do + '" > ' + $Log + ' 2>&1"'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = $cmdline
  $psi.WorkingDirectory = $sim
  $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    taskkill /PID $p.Id /T /F 2>$null | Out-Null
    foreach ($pn in @('vsim','vish','vlm')) {
      Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    return -1
  }
  return $p.ExitCode
}

$t0 = [Diagnostics.Stopwatch]::StartNew()

# --- compile once (fresh work lib) ---
if (-not $KeepWork) {
  $rtl = @(
    '../rtl/common/rst_sync.v', '../rtl/common/timebase.v',
    '../rtl/common/sync_fifo.v', '../rtl/common/crc32.v',
    '../rtl/common/bram_sdp.v',  '../rtl/top/init_sweep.v', '../rtl/top/AFDX_top.v',
    '../rtl/top/stats_regs.v',
    '../rtl/tx/tx_sn_gen.v',     '../rtl/tx/tx_port_buf.v',
    '../rtl/tx/tx_frame_builder.v', '../rtl/tx/tx_vl_scheduler.v',
    '../rtl/tx/tx_rm.v',            '../rtl/tx/tx_pace.v',
    '../rtl/tx/mac_tx_if.v',   '../rtl/rx/mac_rx_if.v',
    '../rtl/rx/rx_block_pool.v', '../rtl/rx/rx_pmem_queue.v',
    '../rtl/rx/rx_ic.v', '../rtl/rx/rx_vl_lookup.v', '../rtl/rx/rx_flt.v',
    '../rtl/rx/rx_rm.v', '../rtl/rx/rx_ip_udp_parse.v', '../rtl/rx/rx_port_buf.v',
    '../rtl/mgmt/mgmt_sap_rx.v', '../rtl/mgmt/snmp_lite.v',
    '../rtl/mgmt/a615a_tftp.v',  '../rtl/mgmt/rtc_sync.v'
  )
  # TB file = tb/<tb>.v; a TB whose file hosts several top modules (e.g.
  # tb_t04g_tx_chain lives in tb_t04_tx_chain.v) is mapped here.
  $tbfile = @{ 'tb_t04g_tx_chain' = 'tb_t04_tx_chain';
               'tb_t08ag_rx_ingress' = 'tb_t08a_rx_ingress';
               'tb_t08bg_top_rx' = 'tb_t08b_top_rx';
               'tb_t08cg_host_arb' = 'tb_t08c_host_arb';
               'tb_t08dg_top_flt' = 'tb_t08d_top_flt';
               'tb_t08eg_top_ic' = 'tb_t08e_top_ic';
               'tb_t08fg_full_scoreboard' = 'tb_t08f_full_scoreboard';
               'tb_t05bg_jitter' = 'tb_t05b_jitter';
               'tb_t13g_latency' = 'tb_t13_latency';
               'tb_t13wg_worst' = 'tb_t13w_worst';
               'tb_t18g_random_stress' = 'tb_t18_random_stress';
               'tb_t23g_sap_min' = 'tb_t23_sap_min';
               'tb_t10g_top_rm' = 'tb_t10_top_rm';
               'tb_t11g_top_port' = 'tb_t11_top_port';
               'tb_t11ig_top_int' = 'tb_t11i_top_int';
               'tb_t17g_min_frame_stress' = 'tb_t17_min_frame_stress';
               'tb_t21g_block_pool' = 'tb_t21_block_pool';
               'tb_t22g_top_loopback' = 'tb_t22_top_loopback';
               'tb_t09s_rx_ic' = 'tb_t09_rx_ic';
               'tb_t09ps_rx_ic' = 'tb_t09p_rx_ic';
               'tb_t12c_lookup' = 'tb_t12_rx_lookup';
               'tb_t12r_lookup' = 'tb_t12_rx_lookup';
               'tb_t12s_lookup' = 'tb_t12_rx_lookup';
               'tb_t12h_lookup' = 'tb_t12_rx_lookup';
               'tb_t12fg_top_lookup' = 'tb_t12f_top_lookup';
               'tb_t14_stats_regs_gmii' = 'tb_t14_stats_regs';
               'tb_t15_snmp_gmii' = 'tb_t15_snmp';
               'tb_t15cg_snmp_bag' = 'tb_t15c_snmp_bag';
               'tb_t16_tftp_rtc_gmii' = 'tb_t16_tftp_rtc' }
  $tbs = @(); foreach ($m in $manifest) {
    $f = if ($tbfile.ContainsKey($m.Tb)) { $tbfile[$m.Tb] } else { $m.Tb }
    $tbs += ('tb/' + $f + '.v')
  }
  $env:VLOG_SRC = (($rtl + ($tbs | Select-Object -Unique)) -join ' ')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $compileLog = $OutDir + '/compile_console.txt'
  $rc = Run-Vsim 'source compile.tcl' $compileLog 300
  Write-Output ("COMPILE rc=" + $rc + " wall_s=" + [math]::Round($sw.Elapsed.TotalSeconds,1))
  if ($rc -ne 0) {
    Write-Output "ERROR: compile session failed; log follows:"
    Get-Content $compileLog -Encoding UTF8 | Write-Output
    exit 1
  }
  # vlog prints "Errors: N, Warnings: M" - parse it (tcl exit code alone
  # does not catch vlog errors when Questa still exits 0)
  $errLine = (Select-String -Path $compileLog -Pattern 'Errors:\s*(\d+)') |
             Select-Object -Last 1
  $nErr = if ($errLine) { [int]$errLine.Matches[0].Groups[1].Value } else { 99 }
  if ($nErr -ne 0) {
    Write-Output ("ERROR: vlog reported " + $nErr + " error(s); log follows:")
    Get-Content $compileLog -Encoding UTF8 | Write-Output
    exit 1
  }
  Write-Output "COMPILE OK (0 errors)"
}

# --- run each test in its own vsim session ---
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('test_id,config,tb,result,max_dev,wall_s,summary')
$npass = 0
$idx = 0
foreach ($m in $manifest) {
  $idx++
  $log = $OutDir + '/' + $m.Id + '_console.txt'
  $env:TEST_TB = $m.Tb
  if ($Coverage) {
    $env:UCDB_OUT = Join-Path $coverageRoot ($m.Id + '.ucdb')
    Remove-Item $env:UCDB_OUT -Force -ErrorAction SilentlyContinue
  } else {
    Remove-Item Env:UCDB_OUT -ErrorAction SilentlyContinue
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rc = Run-Vsim 'source run_one.tcl' $log 600
  $wall = [math]::Round($sw.Elapsed.TotalSeconds,1)
  # strict verdict (A04): see regress_verdict.ps1
  $lines = @()
  if (Test-Path $log) { $lines = @(Get-Content $log -Encoding UTF8) }
  $vd = Get-TestVerdict -Id $m.Id -Lines ([string[]]$lines) -Rc $rc
  $result = $vd.Result
  if ($result -eq 'PASS') { $npass++; $verdict = $vd.Verdict }
  elseif ($vd.Verdict -ne '') { $verdict = $vd.Reason + ' | ' + $vd.Verdict }
  else { $verdict = $vd.Reason }
  $summary = $verdict -replace ',', ';'
  $rows.Add(($m.Id + ',' + $m.Cfg + ',' + $m.Tb + ',' + $result + ',na,' + $wall + ',' + $summary))
  Write-Output ("[" + $idx + "/" + $manifest.Count + "] " + $m.Id + " " + $m.Tb + " -> " + $result + " (" + $wall + " s) " + $verdict)
}

$csvPath = Join-Path (Join-Path $sim $OutDir) 'regress.csv'
[IO.File]::WriteAllLines($csvPath, $rows)
Write-Output ("REGRESS SUMMARY: " + $npass + "/" + $manifest.Count + " pass, wall_s=" + [math]::Round($t0.Elapsed.TotalSeconds,1))
Write-Output ("CSV: " + $OutDir + "/regress.csv")
$rows | Write-Output
if ($npass -ne $manifest.Count) { exit 1 }
exit 0
