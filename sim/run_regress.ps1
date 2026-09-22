# =====================================================================
# run_regress.ps1 - regression runner (design doc 12.4, week-1 skeleton)
# Usage (from sim/):  powershell -ExecutionPolicy Bypass -File .\run_regress.ps1
#   optional:  -Tests T00,T01   (subset)   -KeepWork  (skip recompile)
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
if (-not (Test-Path out)) { New-Item -ItemType Directory -Path out | Out-Null }

# --- manifest ---
$manifest = @()
foreach ($line in (Get-Content (Join-Path $sim 'tests.manifest') -Encoding UTF8)) {
  $t = "$line".Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $p = $t -split '\s+'
  $cfg = if ($p.Count -gt 2) { $p[2] } else { 'default' }
  $manifest += [pscustomobject]@{ Id = $p[0]; Tb = $p[1]; Cfg = $cfg }
}
if ($Tests.Count -gt 0) { $manifest = @($manifest | Where-Object { $Tests -contains $_.Id }) }
if ($manifest.Count -eq 0) { Write-Output "ERROR: no tests selected"; exit 1 }
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
    '../rtl/common/bram_sdp.v',  '../rtl/top/AFDX_top.v',
    '../rtl/tx/tx_sn_gen.v',     '../rtl/tx/tx_port_buf.v'
  )
  $tbs = @(); foreach ($m in $manifest) { $tbs += ('tb/' + $m.Tb + '.v') }
  $env:VLOG_SRC = (($rtl + ($tbs | Select-Object -Unique)) -join ' ')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rc = Run-Vsim 'source compile.tcl' 'out/compile_console.txt' 300
  Write-Output ("COMPILE rc=" + $rc + " wall_s=" + [math]::Round($sw.Elapsed.TotalSeconds,1))
  if ($rc -ne 0) {
    Write-Output "ERROR: compile session failed; log follows:"
    Get-Content out/compile_console.txt -Encoding UTF8 | Write-Output
    exit 1
  }
  # vlog prints "Errors: N, Warnings: M" - parse it (tcl exit code alone
  # does not catch vlog errors when Questa still exits 0)
  $errLine = (Select-String -Path out/compile_console.txt -Pattern 'Errors:\s*(\d+)') |
             Select-Object -Last 1
  $nErr = if ($errLine) { [int]$errLine.Matches[0].Groups[1].Value } else { 99 }
  if ($nErr -ne 0) {
    Write-Output ("ERROR: vlog reported " + $nErr + " error(s); log follows:")
    Get-Content out/compile_console.txt -Encoding UTF8 | Write-Output
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
  $log = 'out/' + $m.Id + '_console.txt'
  $env:TEST_TB = $m.Tb
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rc = Run-Vsim 'source run_one.tcl' $log 600
  $wall = [math]::Round($sw.Elapsed.TotalSeconds,1)
  $verdict = ''
  if (Test-Path $log) {
    foreach ($l in (Get-Content $log -Encoding UTF8)) {
      if ("$l" -match '(PASS|FAIL)') { $verdict = "$l".Trim() }
    }
  }
  $result = 'FAIL'
  if ($rc -eq 0 -and $verdict -match 'PASS' -and $verdict -notmatch 'FAIL') {
    $result = 'PASS'; $npass++
  } elseif ($rc -eq -1) {
    $verdict = 'TIMEOUT(600s)'
  } elseif ($verdict -eq '') {
    $verdict = ('no verdict line, vsim rc=' + $rc)
  }
  $summary = $verdict -replace ',', ';'
  $rows.Add(($m.Id + ',' + $m.Cfg + ',' + $m.Tb + ',' + $result + ',na,' + $wall + ',' + $summary))
  Write-Output ("[" + $idx + "/" + $manifest.Count + "] " + $m.Id + " " + $m.Tb + " -> " + $result + " (" + $wall + " s) " + $verdict)
}

[IO.File]::WriteAllLines((Join-Path $sim 'out/regress.csv'), $rows)
Write-Output ("REGRESS SUMMARY: " + $npass + "/" + $manifest.Count + " pass, wall_s=" + [math]::Round($t0.Elapsed.TotalSeconds,1))
Write-Output "CSV: out/regress.csv"
$rows | Write-Output
if ($npass -ne $manifest.Count) { exit 1 }
exit 0
