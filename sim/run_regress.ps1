# =====================================================================
# run_regress.ps1 - regression runner (design doc 12.4, week-1 skeleton)
# Usage (from sim/):  powershell -ExecutionPolicy Bypass -File .\run_regress.ps1
#   optional:  -Tests T00,T01   (subset)   -KeepWork (rejected; always fresh)
#              -OutDir out/neg_t13  (must be a new, non-empty-safe directory)
#              -PlusArgs '+T13_TOTAL_MAX_US=5'  (passed to every vsim)
# Verdict: strict, see regress_verdict.ps1 (audit 20260928 A04) - one
# verdict line per test, no FAIL/Error text, clean simulator summary.
# Copies inputs into a unique run workspace, compiles once, and runs each TB
# in its own vsim session. Output, vectors, metrics, coverage and work are isolated.
# Automation hosts must allow simulator process startup. On this machine,
# a restricted sandbox returns Win32 623; the same executable works outside it.
# See SIMULATOR_STARTUP.md for the reproduced diagnosis and invocation.
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
  ,[string]$OutDir = ''       # defaults to a unique directory under sim/out
  ,[string]$PlusArgs = ''    # e.g. '+T13_TOTAL_MAX_US=5' for negative runs
  ,[string]$VsimPath = ''    # optional exact simulator executable path
)
$ErrorActionPreference = 'Stop'

# --- locate vsim (same candidate list as run_t01.ps1) ---
$cands = @(
  "C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe",
  "C:\intelFPGA\20.1\modelsim_ase\win32aloem\vsim.exe"
)
$vsim = $null
if ($VsimPath -ne '') {
  if (Test-Path -LiteralPath $VsimPath -PathType Leaf) { $vsim = [IO.Path]::GetFullPath($VsimPath) }
  else { Write-Output "ERROR: requested VsimPath not found: '$VsimPath'"; exit 1 }
} elseif ($env:VSIM_EXE -and (Test-Path -LiteralPath $env:VSIM_EXE -PathType Leaf)) {
  $vsim = [IO.Path]::GetFullPath($env:VSIM_EXE)
}
foreach ($c in $cands) { if (-not $vsim -and (Test-Path $c)) { $vsim = $c; break } }
if (-not $vsim -and -not $VsimPath) {
  $f = Get-ChildItem "C:\altera_pro" -Recurse -Filter "vsim.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { $vsim = $f.FullName }
}
if (-not $vsim) { Write-Output "ERROR: vsim.exe not found"; exit 1 }

# --- license env (Starter SALT keyring, see run_t01.ps1) ---
$licUser = [Environment]::GetEnvironmentVariable('SALT_LICENSE_SERVER','User')
if (-not $env:SALT_LICENSE_SERVER -and $licUser) { $env:SALT_LICENSE_SERVER = $licUser }
if (-not $env:SALT_LICENSE_SERVER) { Write-Output "ERROR: SALT_LICENSE_SERVER not set"; exit 1 }

# A path existing on disk does not prove the Windows loader can start it.
$probeInfo = New-Object System.Diagnostics.ProcessStartInfo
$probeInfo.FileName = $vsim
$probeInfo.Arguments = '-version'
$probeInfo.WorkingDirectory = $PSScriptRoot
$probeInfo.UseShellExecute = $false
$probeInfo.CreateNoWindow = $true
$probeInfo.RedirectStandardOutput = $true
$probeInfo.RedirectStandardError = $true
try {
  $probe = [System.Diagnostics.Process]::Start($probeInfo)
  $probeOutTask = $probe.StandardOutput.ReadToEndAsync()
  $probeErrTask = $probe.StandardError.ReadToEndAsync()
  if (-not $probe.WaitForExit(15000)) {
    taskkill /PID $probe.Id /T /F 2>$null | Out-Null
    throw 'version probe timed out after 15 seconds'
  }
  $vsimVersionText = (($probeOutTask.Result + "`n" + $probeErrTask.Result).Trim())
  $vsimVersionRc = $probe.ExitCode
} catch {
  $startupError = $_.Exception
  while ($startupError.InnerException) { $startupError = $startupError.InnerException }
  Write-Output ("ERROR: simulator cannot start: " + $startupError.Message)
  if ($startupError -is [ComponentModel.Win32Exception]) {
    Write-Output ("ERROR: simulator startup native_error_code=" + $startupError.NativeErrorCode)
    if ($startupError.NativeErrorCode -eq 623) {
      Write-Output 'HINT: this failed before HDL compilation. On this machine Win32 623 is reproduced inside the restricted automation sandbox; rerun the same command outside that sandbox. See sim/SIMULATOR_STARTUP.md.'
    }
  }
  exit 1
}
if ($vsimVersionRc -ne 0 -or $vsimVersionText -eq '') {
  Write-Output ("ERROR: simulator version probe failed (rc=" + $vsimVersionRc + "): " + $vsimVersionText)
  exit 1
}

# Never terminate processes by executable name. Each simulator is launched by
# this run and, on timeout, only that cmd.exe process tree is terminated below.
if ($KeepWork) {
  Write-Output 'ERROR: -KeepWork is disabled; an isolated run always starts with a fresh library.'
  exit 1
}
$sourceSim = $PSScriptRoot
$sourceRoot = Split-Path -Parent $sourceSim
$OutDir = $OutDir.Trim().TrimEnd('/', '\')
if ($OutDir -eq '') {
  $runLeaf = 'regress_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $OutDir = Join-Path 'out' $runLeaf
}
if ($OutDir -match '[\s"&|<>]') { Write-Output "ERROR: bad -OutDir '$OutDir'"; exit 1 }
if ([IO.Path]::IsPathRooted($OutDir)) { $runOutput = [IO.Path]::GetFullPath($OutDir) }
else { $runOutput = [IO.Path]::GetFullPath((Join-Path $sourceSim $OutDir)) }
$outRoot = [IO.Path]::GetFullPath((Join-Path $sourceSim 'out')).TrimEnd('\') + '\'
if (-not $runOutput.StartsWith($outRoot, [StringComparison]::OrdinalIgnoreCase)) {
  Write-Output "ERROR: -OutDir must resolve under '$outRoot'"; exit 1
}
if (Test-Path -LiteralPath $runOutput) {
  if (@(Get-ChildItem -LiteralPath $runOutput -Force).Count -gt 0) {
    Write-Output "ERROR: refusing to overwrite non-empty run directory '$runOutput'"; exit 1
  }
} else {
  New-Item -ItemType Directory -Path $runOutput -Force | Out-Null
}

# A private source copy makes this run immune to concurrent edits and prevents
# generator, work-library, metric and testbench outputs from touching old runs.
$snapshotRoot = Join-Path $runOutput 'workspace'
New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
$copyDirs = @('rtl','sim\tb','sim\bfm','sim\chk','sim\env','sim\vec',
              'sw\golden','sw\report','doc','elinx\sdc')
foreach ($rel in $copyDirs) {
  $src = Join-Path $sourceRoot $rel
  if (Test-Path -LiteralPath $src -PathType Container) {
    $parentRel = Split-Path -Parent $rel
    $destParent = if ($parentRel) { Join-Path $snapshotRoot $parentRel } else { $snapshotRoot }
    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $destParent -Recurse
  }
}
$sourceLists = Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'elinx') -Filter '*.f' -File
$snapshotElinx = Join-Path $snapshotRoot 'elinx'
New-Item -ItemType Directory -Path $snapshotElinx -Force | Out-Null
$sourceLists | Copy-Item -Destination $snapshotElinx
$guiSrc = Join-Path $sourceRoot 'elinx\gui_afdx'
if (Test-Path -LiteralPath $guiSrc -PathType Container) {
  $guiDst = Join-Path $snapshotRoot 'elinx\gui_afdx'
  New-Item -ItemType Directory -Path $guiDst -Force | Out-Null
  Get-ChildItem -LiteralPath $guiSrc -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in '.epr','.qpf','.qsf','.xml','.property' } |
    Copy-Item -Destination $guiDst
  $guiInputs = @(
    @{ Source=(Join-Path $guiSrc 'AFDX_top.pr'); Relative='AFDX_top.pr' },
    @{ Source=(Join-Path $guiSrc 'AFDX_top.srcs\constrs_1\new'); Relative='AFDX_top.srcs\constrs_1\new' }
  )
  foreach ($entry in $guiInputs) {
    if (Test-Path -LiteralPath $entry.Source -PathType Container) {
      $target = Join-Path $guiDst $entry.Relative
      New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
      Copy-Item -LiteralPath $entry.Source -Destination (Split-Path -Parent $target) -Recurse
    }
  }
}
$prjSrc = Join-Path $sourceRoot 'elinx\prj'
if (Test-Path -LiteralPath $prjSrc -PathType Container) {
  Get-ChildItem -LiteralPath $prjSrc -Recurse -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in '.ys','.tcl','.sdc','.qsf','.qpf' } |
    ForEach-Object {
      $relativePath = $_.FullName.Substring($prjSrc.Length + 1)
      $target = Join-Path (Join-Path $snapshotRoot 'elinx\prj') $relativePath
      New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $target
    }
}
$sim = Join-Path $snapshotRoot 'sim'
$projectRoot = $snapshotRoot
New-Item -ItemType Directory -Path $sim -Force | Out-Null
# Questa writes these files in its current directory. They are runtime outputs,
# not regression inputs; copying or hashing them makes a run snapshot depend on
# whichever simulator session happened to run most recently.
$simRuntimeOutputs = @('transcript','vsim_stacktrace.vstf','vish_stacktrace.vstf','vsim.wlf')
Get-ChildItem -LiteralPath $sourceSim -File |
  Where-Object { $simRuntimeOutputs -notcontains $_.Name } |
  Copy-Item -Destination $sim
$toolCopy = Join-Path $snapshotRoot 'tools'
New-Item -ItemType Directory -Path $toolCopy -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'tools') -File |
  Where-Object { $_.Extension -in '.py','.md' } | Copy-Item -Destination $toolCopy
foreach ($rel in @('README.md','_project.md','AFDX端系统_总体设计书.md','elinx\README.txt')) {
  $src = Join-Path $sourceRoot $rel
  if (Test-Path -LiteralPath $src -PathType Leaf) {
    $dst = Join-Path $snapshotRoot $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst
  }
}
Set-Location $sim
$env:RUN_ISOLATED = '1'
. (Join-Path $sim 'regress_verdict.ps1')
New-Item -ItemType Directory -Force -Path (Join-Path $sim 'out/metrics') | Out-Null
$met = Join-Path $sim 'out/metrics'
Set-Content -Path (Join-Path $met 'cover_ic.csv') -Value 'ok,reset,lost1,first_any,first_fail,ooo,badvl,net_a,net_b'
Set-Content -Path (Join-Path $met 'cover_rm.csv') -Value 'fwd,dup,skew,bypass'
if ($PlusArgs -ne '') { $env:VSIM_PLUSARGS = $PlusArgs } else { Remove-Item Env:VSIM_PLUSARGS -ErrorAction SilentlyContinue }
$coverageRoot = Join-Path $runOutput 'coverage'
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
  if ($p.Count -lt 2) { Write-Output "ERROR: malformed manifest row: '$t'"; exit 1 }
  $cfg = if ($p.Count -gt 2) { $p[2] } else { 'default' }
  $manifest += [pscustomobject]@{ Id = $p[0]; Tb = $p[1]; Cfg = $cfg }
}
$dupIds = @($manifest | Group-Object Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupIds.Count -gt 0) { Write-Output ("ERROR: duplicate test id(s) in manifest: " + ($dupIds -join ',')); exit 1 }
$scopePath = Join-Path $sim 'bind_scope.tsv'
$profilesPath = Join-Path $sim 'bind_scope_profiles.tsv'
$scopeAudit = Join-Path $sim 'check_bind_scope.py'
if (-not (Test-Path -LiteralPath $scopePath) -or -not (Test-Path -LiteralPath $profilesPath) -or -not (Test-Path -LiteralPath $scopeAudit)) { Write-Output 'ERROR: bind scope inputs missing'; exit 1 }
& python $scopeAudit --source-root $projectRoot --sim-dir $sim --scope $scopePath --profiles $profilesPath
if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: bind scope audit failed'; exit 1 }
$scopeRows = @(Import-Csv -LiteralPath $scopePath -Delimiter "`t")
if ($scopeRows.Count -ne $manifest.Count) { Write-Output "ERROR: bind scope row count $($scopeRows.Count) != manifest count $($manifest.Count)"; exit 1 }
$bindTopById = @{}
foreach ($scopeRow in $scopeRows) {
  $mapped = @($manifest | Where-Object { $_.Id -eq $scopeRow.test_id })
  if ($mapped.Count -ne 1 -or $mapped[0].Tb -ne $scopeRow.tb) { Write-Output "ERROR: bind scope id/TB mismatch: $($scopeRow.test_id)/$($scopeRow.tb)"; exit 1 }
  $top = switch ($scopeRow.profile) { 'full' {'afdx_bind_full'} 'rx_ic' {'afdx_bind_rx_ic'} 'mac_tx_if' {'afdx_bind_mac_tx_if'} 'none' {'none'} default {$null} }
  if ($null -eq $top) { Write-Output "ERROR: unmapped bind profile '$($scopeRow.profile)' for $($scopeRow.test_id)"; exit 1 }
  $bindTopById[$scopeRow.test_id] = $top
}
if (@($bindTopById.Keys).Count -ne $manifest.Count) { Write-Output 'ERROR: bind scope duplicate or missing test IDs'; exit 1 }
# powershell -File passes "-Tests T00,T01" as one string (not a string[]).
# Accept both that documented spelling and -Command's array spelling.
if ($Tests.Count -gt 0) {
  $selected = @($Tests | ForEach-Object { $_ -split ',' } |
                ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  $dupSelected = @($selected | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  if ($dupSelected.Count -gt 0) { Write-Output ("ERROR: duplicate requested test id(s): " + ($dupSelected -join ',')); exit 1 }
  $unknown = @($selected | Where-Object { @($manifest.Id) -notcontains $_ })
  if ($unknown.Count -gt 0) { Write-Output ("ERROR: unknown test id(s): " + ($unknown -join ',')); exit 1 }
  $manifest = @($manifest | Where-Object { $selected -contains $_.Id })
}
if ($manifest.Count -eq 0) { Write-Output "ERROR: no tests selected"; exit 1 }
if (@($manifest | Where-Object { $_.Id -eq 'T31' -or $_.Id -eq 'T31g' -or $_.Id -eq 'T36' -or $_.Id -eq 'T36g' }).Count -gt 0) {
  $snmpChecker = Join-Path $sim 'check_snmp_wire_capture.py'
  if (-not (Test-Path -LiteralPath $snmpChecker -PathType Leaf)) {
    Write-Output "ERROR: SNMP on-wire tests require the independent SNMP wire checker: $snmpChecker"
    exit 1
  }
  & python $snmpChecker --self-test
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: independent SNMP wire checker self-test failed'
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -in @('T35','T35g','T35p') }).Count -gt 0) {
  $t35Checker = Join-Path $sim 'check_t35_coverage.py'
  if (-not (Test-Path -LiteralPath $t35Checker -PathType Leaf)) {
    Write-Output "ERROR: T35/T35g requires the independent full-index coverage checker: $t35Checker"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -eq 'T09' -or $_.Id -eq 'T09s' }).Count -gt 0) {
  # Generate the oracle before any T09 session; a failed model is a failed run.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t09_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T09 Python golden vector generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T15*' -or $_.Id -like 'T16*' -or $_.Id -like 'T24*' -or $_.Id -like 'T25*' -or $_.Id -like 'T31*' -or $_.Id -like 'T32*' -or $_.Id -like 'T36*' -or $_.Id -like 'T37*' -or $_.Id -like 'T40*' }).Count -gt 0) {
  # continue4: T15/T16/T24/T25 use SAP golden frames (SNMP BER + TFTP) with
  # afdx_model + zlib wire-order FCS.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t15_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T15/T16/T24/T25 management golden vector generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -eq 'T36' -or $_.Id -eq 'T36g' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t36_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T36 malformed SNMP vector generation failed"
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
if (@($manifest | Where-Object { $_.Id -like 'T12*' -or $_.Id -like 'T08f*' -or
     $_.Id -like 'T35*' -or $_.Id -eq 'T60' -or $_.Id -in @('T65','T66','T67') }).Count -gt 0) {
  # T12 and T08f need both tables and independent key lists; offline rejection
  # must fail the regression instead of running against an old partial image.
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t12_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: T12 offline hash image generation failed"
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T35*' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t35_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T35 independent full-index live-frame vector generation failed'
    exit 1
  }
}
# P08 (2026-10-11): IPv4 fragment reassembly end-to-end golden vectors.
if (@($manifest | Where-Object { $_.Id -eq 'T60' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t60_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T60 reassembly fragment vector generation failed'
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -like 'T64*' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t64_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T64 reassembled UDP checksum vector generation failed'
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -in @('T65','T66','T67') }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t65_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T65/T66/T67 reassembly metadata/contention vector generation failed'
    exit 1
  }
}
# T79: short first/later IPv4 fragments at the Ethernet minimum frame boundary.
if (@($manifest | Where-Object { $_.Id -eq 'T79' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t79_rx_frag_minlen.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T79 fragment minimum-length vector generation failed'
    exit 1
  }
}
# P05 (2026-10-11): 615A fetch-engine GMII-level loader downlink frames.
# T80: independent full-message/fragment and dual-GMII golden vectors.
if (@($manifest | Where-Object { $_.Id -eq 'T82' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t82_tx8k.py') --out (Join-Path $sim 'vec/t82_tx8k') --verify-existing
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T82 production TX8KiB golden generation failed'
    exit 1
  }
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t82_recovery.py') --out (Join-Path $sim 'vec/t82_recovery') --verify-existing
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T82 metadata-fault recovery golden generation failed'
    exit 1
  }
}
# T80: independent full-message/fragment and dual-GMII golden vectors.
# --verify-existing: clean checkout may already ship vec/tx_fragment_builder
# (same pattern as T82/T83/T84). Refuse silent rewrite of frozen fixtures.
if (@($manifest | Where-Object { $_.Id -eq 'T80' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_tx_fragment_builder.py') --out (Join-Path $sim 'vec/tx_fragment_builder') --verify-existing
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T80 TX fragment vector generation failed'
    exit 1
  }
}
# T83: one production DUT, TX4/RX5, host and TFTP contention/recovery.
if (@($manifest | Where-Object { $_.Id -in @('T83','T86') }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t83_coexist.py') --out (Join-Path $sim 'vec/t83_coexist') --verify-existing
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T83 coexistence golden generation failed'
    exit 1
  }
}
# P05 (2026-10-11): 615A fetch-engine GMII-level loader downlink frames.
if (@($manifest | Where-Object { $_.Id -eq 'T84' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t84_init_source.py') --out (Join-Path $sim 'vec/t84_init_source') --verify-existing
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T84 initialization ACK golden verification failed'
    exit 1
  }
}
if (@($manifest | Where-Object { $_.Id -eq 'T57' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t57_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T57 fetch-engine loader vector generation failed'
    exit 1
  }
}
# P05 (2026-10-11): 615A LUR top-level upload -> per-file fetch GMII frames.
if (@($manifest | Where-Object { $_.Id -eq 'T62' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t62_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T62 LUR top-level vector generation failed'
    exit 1
  }
}
# P05 (2026-10-11): 615A LUR host observation read-path (0xAC88/89/8A/8B) frames.
if (@($manifest | Where-Object { $_.Id -eq 'T63' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t63_vectors.py')
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'ERROR: T63 LUR host read-path vector generation failed'
    exit 1
  }
}

if (@($manifest | Where-Object { $_.Id -in @('T41','T42') }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_gmii_vectors.py')
  if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: PHY GMII vector generation failed'; exit 1 }
}
if (@($manifest | Where-Object { $_.Id -in @('T43','T85') }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_gmii_management.py')
  if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: PHY management vector generation failed'; exit 1 }
}
# P02 (2026-10-10): top-level TFTP timeout/backpressure contract vectors.
if (@($manifest | Where-Object { $_.Id -eq 'T45' }).Count -gt 0) {
  python (Join-Path (Split-Path -Parent $sim) 'sw/golden/gen_t45_vectors.py')
  if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: T45 timeout-contract vector generation failed'; exit 1 }
}

# Bind the exact copied sources and generated vectors before compilation.
$hashFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
  Where-Object {
    $relativePath = $_.FullName.Substring($projectRoot.Length + 1).Replace('\','/')
    $relativePath -notmatch '^sim/(out|work)(/|$)' -and
      $_.Extension -ne '.pyc' -and
      ($relativePath -notmatch '^sim/(transcript|vsim_stacktrace\.vstf|vish_stacktrace\.vstf|vsim\.wlf)$')
  } |
  Sort-Object FullName
if (@($hashFiles).Count -eq 0) { throw 'No source inputs found in the isolated snapshot.' }
$sourceHashes = [ordered]@{}
foreach ($f in $hashFiles) {
  $rel = $f.FullName.Substring($projectRoot.Length + 1).Replace('\','/')
  $sourceHashes[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$head = (& git -C $sourceRoot rev-parse HEAD 2>$null | Select-Object -First 1)
$statusLines = @(& git -C $sourceRoot status --porcelain=v1 -uall 2>$null)
$statusText = $statusLines -join "`n"
$sha256 = [Security.Cryptography.SHA256]::Create()
$statusHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($statusText)))).Replace('-','').ToLowerInvariant()
$sha256.Dispose()
$meta = [ordered]@{
  run_id = Split-Path -Leaf $runOutput
  created_local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
  original_workspace = $sourceRoot
  original_git_head = "$head".Trim()
  original_worktree_status_entries = $statusLines.Count
  original_worktree_status_sha256 = $statusHash
  vsim_path = $vsim
  vsim_file_version = [Diagnostics.FileVersionInfo]::GetVersionInfo($vsim).FileVersion
  vsim_version_output = $vsimVersionText
  vsim_executable_sha256 = (Get-FileHash -LiteralPath $vsim -Algorithm SHA256).Hash.ToLowerInvariant()
  coverage_enabled = [bool]$Coverage
  acc_enabled = [bool]$Acc
  plusargs = $PlusArgs
  invocation_parameters = [ordered]@{ Tests=@($Tests); OutDir=$OutDir; PlusArgs=$PlusArgs; VsimPath=$VsimPath; Acc=[bool]$Acc; Coverage=[bool]$Coverage }
  compile_result = 'NOT_RUN'
  regression_result = 'NOT_RUN'
  tests = @($manifest | ForEach-Object { [ordered]@{ id=$_.Id; tb=$_.Tb; config=$_.Cfg } })
  test_results = @()
  source_sha256 = $sourceHashes
}
function Save-RunMetadata {
  $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runOutput 'run_metadata.json') -Encoding utf8
}
Save-RunMetadata
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
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $invocationClock = [Diagnostics.Stopwatch]::StartNew()
  # Some Questa sessions print $finish + "Errors: N" then hang before cmd exits
  # (observed on T42 inside smoke: log PASS at ~50s, runner TIMEOUT 600s).
  # Harvest when the log is complete; do not wait out the full wall budget.
  $logDoneAt = $null
  $graceSec = 20
  try {
    while ($true) {
      $remainingMs = [int][math]::Max(0, $TimeoutSec * 1000 - $invocationClock.ElapsedMilliseconds)
      if ($p.WaitForExit([int][math]::Min(5000, $remainingMs))) { break }
      if ($invocationClock.Elapsed.TotalSeconds -ge $TimeoutSec) {
        taskkill /PID $p.Id /T /F 2>$null | Out-Null
        $p.WaitForExit(10000) | Out-Null
        return -1
      }
      $tailLine = ''
      if (Test-Path -LiteralPath $Log) {
        $tail = @(Get-Content -LiteralPath $Log -Tail 20 -ErrorAction SilentlyContinue)
        if ($tail.Count -gt 0) { $tailLine = $tail[-1] }
        $blob = ($tail -join "`n")
        $finished = ($blob -match '\$finish') -and ($blob -match 'Errors:\s*\d+')
        # Coverage: do NOT harvest — UCDB must flush on clean process exit (D plan).
        if ($finished -and -not $Coverage) {
          if ($null -eq $logDoneAt) {
            $logDoneAt = $invocationClock.Elapsed.TotalSeconds
            Write-Host ("VSIM_LOG_DONE cmd_pid=" + $p.Id + " at_s=" + [math]::Round($logDoneAt,1) + " grace_s=" + $graceSec)
          } elseif (($invocationClock.Elapsed.TotalSeconds - $logDoneAt) -ge $graceSec) {
            Write-Host ("VSIM_HARVEST_AFTER_FINISH cmd_pid=" + $p.Id + " elapsed_s=" + [math]::Round($invocationClock.Elapsed.TotalSeconds,1))
            taskkill /PID $p.Id /T /F 2>$null | Out-Null
            $p.WaitForExit(10000) | Out-Null
            # Log already has end summary; treat as clean exit for verdict.
            return 0
          }
        }
      }
      # Host output must not enter the integer return value captured by $rc.
      Write-Host ("VSIM_PROGRESS cmd_pid=" + $p.Id + " elapsed_s=" + [math]::Round($invocationClock.Elapsed.TotalSeconds,1) + " log=" + [IO.Path]::GetFileName($Log) + " last_line=" + $tailLine)
    }
    return $p.ExitCode
  } finally {
    # On cancellation terminate only this invocation's still-live process tree.
    if (-not $p.HasExited) {
      taskkill /PID $p.Id /T /F 2>$null | Out-Null
      $p.WaitForExit(10000) | Out-Null
    }
    $p.Dispose()
  }
}

$t0 = [Diagnostics.Stopwatch]::StartNew()

# --- compile once (fresh work lib) ---
if (-not $KeepWork) {
  $rtl = @(
    'env/afdx_host_bfm.v', 'env/afdx_net_port.v', 'env/afdx_net_model.v',
    'env/afdx_mac_bfm.v', 'env/afdx_timing_mon.v', 'env/afdx_scoreboard.v',
    'chk/afdx_chk_mac.v', 'chk/afdx_chk_bag.v',
    '../rtl/common/rst_sync.v', '../rtl/common/timebase.v',
    '../rtl/common/sync_fifo.v', '../rtl/common/crc32.v',
    '../rtl/common/bram_sdp.v',  '../rtl/top/init_sweep.v', '../rtl/top/AFDX_top.v',
    '../rtl/top/AFDX_top_chipsim.v',
    '../rtl/top/stats_regs.v',
    '../rtl/tx/tx_sn_gen.v',     '../rtl/tx/tx_port_buf.v',
    '../rtl/tx/tx_frame_builder.v', '../rtl/tx/tx_vl_scheduler.v',
    '../rtl/tx/tx_rm.v',            '../rtl/tx/tx_pace.v',
    '../rtl/tx/mac_tx_if.v',   '../rtl/rx/mac_rx_if.v', '../rtl/rx/gmii_rx_strip.v',
    '../rtl/rx/rx_block_pool.v', '../rtl/rx/rx_pmem_queue.v',
    '../rtl/rx/rx_ic.v', '../rtl/rx/rx_vl_lookup.v', '../rtl/rx/rx_flt.v',
    '../rtl/rx/rx_rm.v', '../rtl/rx/rx_pmem_copy_engine.v', '../rtl/rx/rx_udp_checksum_engine.v', '../rtl/rx/rx_reassembly.v', '../rtl/rx/rx_reassembly_chain.v', '../rtl/rx/rx_pmem_scatter_copy.v', '../rtl/rx/rx_chain_metadata.v', '../rtl/rx/rx_ip_udp_parse.v', '../rtl/rx/rx_port_buf.v',
    '../rtl/mgmt/mgmt_sap_rx.v', '../rtl/mgmt/mgmt_sap_rx_chain.v', '../rtl/mgmt/snmp_lite.v',
    '../rtl/mgmt/a615a_tftp.v',  '../rtl/mgmt/rtc_sync.v',
    # P01 (2026-10-10): preparation modules compiled for their dedicated TBs
    # (T46..T53). They are NOT part of the production elinx source list.
    '../rtl/mgmt/a615a_init_tx.v', '../rtl/mgmt/a615a_lur_rx.v',
    '../rtl/mgmt/a615a_file_rx.v', '../rtl/mgmt/a615a_tftp_client_1350.v',
    '../rtl/mgmt/a615a_tftp_file_rx_adapter.v',
    '../rtl/mgmt/a615a_tftp_dgram_rx.v',
    '../rtl/mgmt/a615a_tftp_tx_pack.v',
    '../rtl/mgmt/a615a_fetch_engine.v',
    '../rtl/mgmt/a615a_lur_orchestrator.v',
    '../rtl/tx/ipv4_fragment_plan.v', '../rtl/tx/ipv4_fragment_header.v',
    '../rtl/tx/tx_pmem_byte_reader.v',
    '../rtl/tx/tx_pmem_window_reader.v',
    '../rtl/tx/tx_fragment_frame_builder.v',
    '../rtl/tx/tx_message_store.v', '../rtl/tx/tx_fragment_launch.v',
    'chk/afdx_chk_a6.v', 'chk/afdx_chk_a7.v', 'chk/afdx_chk_a2.v', 'chk/afdx_chk_a8.v',
    'chk/afdx_chk_a9.v',
    'chk/afdx_chk_a10.v', 'chk/afdx_chk_a11.v',
    'chk/afdx_cov_ic.v', 'chk/afdx_cov_rm.v',
    'chk/afdx_cov_flt.v', 'chk/afdx_cov_rsrc.v',
    'chk/afdx_cover.sv',
    'chk/bind_profiles/afdx_bind_full.sv',
    'chk/bind_profiles/afdx_bind_rx_ic.sv',
    'chk/bind_profiles/afdx_bind_mac_tx_if.sv',
    'tb/tb_afdx_top.sv'
  )
  # TB file = tb/<tb>.v; a TB whose file hosts several top modules (e.g.
  # tb_t04g_tx_chain lives in tb_t04_tx_chain.v) is mapped here.
  $tbfile = @{ 'tb_t64a_rx_udp_checksum' = 'tb_t64_rx_udp_checksum';
               'tb_t64b_rx_udp_checksum' = 'tb_t64_rx_udp_checksum';
               'tb_t04g_tx_chain' = 'tb_t04_tx_chain';
               'tb_t08ag_rx_ingress' = 'tb_t08a_rx_ingress';
               'tb_t08bg_top_rx' = 'tb_t08b_top_rx';
               'tb_t08cg_host_arb' = 'tb_t08c_host_arb';
               'tb_t08dg_top_flt' = 'tb_t08d_top_flt';
               'tb_t08eg_top_ic' = 'tb_t08e_top_ic';
               'tb_t08fg_full_scoreboard' = 'tb_t08f_full_scoreboard';
               'tb_t35g_rx4096' = 'tb_t35_rx4096';
               'tb_t35p_rx4096' = 'tb_t35_rx4096';
               'tb_t38g_mac_len' = 'tb_t38_mac_len';
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
               'tb_t16_tftp_rtc_gmii' = 'tb_t16_tftp_rtc';
               'tb_s5_vl128_continuous' = 'tb_s5_vl128';
               'tb_s5_vl128_continuous_gmii' = 'tb_s5_vl128';
               'tb_s5_vl128_100rounds' = 'tb_s5_vl128';
               'tb_s5_vl128_continuous_phy' = 'tb_s5_vl128';
               'tb_s5_vl128_100rounds_phy' = 'tb_s5_vl128';
               'tb_s1_es_comm' = 'tb_s1_es_comm';
               'tb_s1_es_comm_gmii' = 'tb_s1_es_comm';
               'tb_s7_snmp_onwire_gmii' = 'tb_s7_snmp_onwire';
               'tb_t36g_snmp_onwire' = 'tb_t36_snmp_onwire';
               'tb_s8_tftp_onwire_gmii' = 'tb_s8_tftp_onwire';
               'tb_t37g_tftp_multiblock' = 'tb_t37_tftp_multiblock';
               'tb_t40_tftp_capacity' = 'tb_t37_tftp_multiblock';
               'tb_t40g_tftp_capacity' = 'tb_t37_tftp_multiblock';
               'tb_t39g_rtc_top' = 'tb_t39_rtc_top' }
  $tbs = @(); foreach ($m in $manifest) {
    $f = if ($tbfile.ContainsKey($m.Tb)) { $tbfile[$m.Tb] } else { $m.Tb }
    $tbs += ('tb/' + $f + '.v')
  }
  $env:VLOG_SRC = (($rtl + ($tbs | Select-Object -Unique)) -join ' ')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $compileLog = Join-Path $runOutput 'compile_console.txt'
  $rc = Run-Vsim 'source compile.tcl' $compileLog 300
  Write-Output ("COMPILE rc=" + $rc + " wall_s=" + [math]::Round($sw.Elapsed.TotalSeconds,1))
  if ($rc -ne 0) {
    $meta.compile_result = 'FAIL'
    $meta.compile_rc = $rc
    Save-RunMetadata
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
    $meta.compile_result = 'FAIL'
    $meta.compile_rc = $rc
    $meta.vlog_errors = $nErr
    Save-RunMetadata
    Write-Output ("ERROR: vlog reported " + $nErr + " error(s); log follows:")
    Get-Content $compileLog -Encoding UTF8 | Write-Output
    exit 1
  }
  $meta.compile_result = 'PASS'
  $meta.compile_rc = $rc
  $meta.vlog_errors = 0
  Save-RunMetadata
  Write-Output "COMPILE OK (0 errors)"
}

# --- run each test in its own vsim session ---
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('test_id,config,tb,result,max_dev,wall_s,summary')
$npass = 0
$idx = 0
$partialCsvPath = Join-Path $runOutput 'regress.partial.csv'
$meta.regression_result = 'RUNNING'
$meta.tests_completed = 0
Save-RunMetadata
foreach ($m in $manifest) {
  $idx++
  $log = Join-Path $runOutput ($m.Id + '_console.txt')
  $env:TEST_TB = $m.Tb
  $env:TEST_BIND_TOP = $bindTopById[$m.Id]
  if ($Coverage) {
    $env:UCDB_OUT = Join-Path $coverageRoot ($m.Id + '.ucdb')
    Remove-Item $env:UCDB_OUT -Force -ErrorAction SilentlyContinue
  } else {
    Remove-Item Env:UCDB_OUT -ErrorAction SilentlyContinue
  }
  $cap = 600
  if ($m.Id -eq 'T27') { $cap = 3600 }
  if ($m.Id -eq 'T29') { $cap = 1200 }
  # Same 100-round workload as T34, with complete PHY capture/audit. The
  # simulation time limit and protocol assertions are unchanged; only host
  # wall-clock allowance accommodates full-size top elaboration and I/O.
  # T34 same 100-round VL128 workload as T34p; wall-clock only (sim asserts unchanged).
  if ($m.Id -eq 'T34' -or $m.Id -eq 'T34p') { $cap = 1800 }
  if ($m.Id -eq 'T89') { $cap = 1200 }
  if ($m.Id -eq 'T90') { $cap = 1800 }
  if ($m.Id -eq 'T88') { $cap = 900 }
  $meta.current_test = $m.Id
  $meta.current_test_started_local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
  Save-RunMetadata
  Write-Output ("START [" + $idx + "/" + $manifest.Count + "] " + $m.Id + " " + $m.Tb + " timeout_s=" + $cap)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rc = Run-Vsim 'source run_one.tcl' $log $cap
  $wall = [math]::Round($sw.Elapsed.TotalSeconds,1)
  # strict verdict (A04): see regress_verdict.ps1
  $lines = @()
  if (Test-Path $log) { $lines = @(Get-Content $log -Encoding UTF8) }
  $vd = Get-TestVerdict -Id $m.Id -Lines ([string[]]$lines) -Rc $rc
  $semanticNote = ''
  if ($vd.Result -eq 'PASS' -and ($m.Id -eq 'T31' -or $m.Id -eq 'T31g')) {
    $semanticJson = Join-Path $runOutput ($m.Id + '_semantic.json')
    & python (Join-Path $sim 'check_snmp_wire_capture.py') $log --json-out $semanticJson
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent SNMP wire semantic check failed'; Verdict='' }
    } else {
      $semanticNote = 'SNMP BER, peer, checksum and FCS PASS'
    }
  }
  if ($vd.Result -eq 'PASS' -and ($m.Id -eq 'T36' -or $m.Id -eq 'T36g')) {
    $semanticJson = Join-Path $runOutput ($m.Id + '_semantic.json')
    & python (Join-Path $sim 'check_snmp_wire_capture.py') $log --case-spec (Join-Path $sim 'case_specs.json') --json-out $semanticJson
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent T36 SNMP case-spec semantic check failed'; Verdict='' }
    } else {
      $semanticNote = 'SNMP case-spec BER, peer, checksum and FCS PASS'
    }
  }
  if ($vd.Result -eq 'PASS' -and ($m.Id -in @('T35','T35g','T35p'))) {
    $auditJson = Join-Path $runOutput ($m.Id + '_coverage_check.json')
    $auditDir = Join-Path $runOutput ($m.Id + '_coverage')
    $phyAuditArgs = @()
    if ($m.Id -eq 'T35p') {
      $phyAuditArgs = @('--phy-a', (Join-Path $met 't35_phy_a.hex'),
                        '--phy-b', (Join-Path $met 't35_phy_b.hex'),
                        '--cycles-a', (Join-Path $met 't35_phy_a_cycles.txt'),
                        '--cycles-b', (Join-Path $met 't35_phy_b_cycles.txt'))
    }
    & python (Join-Path $sim 'check_t35_coverage.py') $log `
      --mapping (Join-Path $sim 'vec/t35_mapping.csv') `
      --frames-hash (Join-Path $sim 'vec/t35_frames.sha256') `
      --frames (Join-Path $sim 'vec/t35_frames.hex') `
      --out-dir $auditDir @phyAuditArgs
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent T35 4096-bit host-delivery audit failed'; Verdict='' }
    } else {
      Copy-Item -LiteralPath (Join-Path $auditDir 'coverage_check.json') -Destination $auditJson -Force
      $semanticNote = 'independent host payload/4096-bit coverage audit passed'
    }
  }
  $result = $vd.Result
  if ($vd.Result -eq 'PASS' -and ($m.Id -eq 'T89')) {
    foreach ($fn in @('t89_metrics.csv', 't89_verilog_summary.json')) {
      $src = Join-Path $sim $fn
      if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $runOutput $fn) -Force
      }
    }
    & python (Join-Path $sourceRoot 'tools\t89_metrics_check.py') $runOutput
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent T89 metrics CSV/JSON check failed'; Verdict='' }
    } else {
      $semanticNote = 'independent T89 CSV/JSON metrics check PASS'
    }
  }
  if ($vd.Result -eq 'PASS' -and ($m.Id -eq 'T90')) {
    foreach ($fn in @('t90_metrics.csv', 't90_verilog_summary.json')) {
      $src = Join-Path $sim $fn
      if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $runOutput $fn) -Force
      }
    }
    & python (Join-Path $sourceRoot 'tools\t90_metrics_check.py') $runOutput
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent T90 metrics CSV/JSON check failed'; Verdict='' }
    } else {
      $semanticNote = 'independent T90 CSV/JSON metrics check PASS'
    }
  }
  if ($vd.Result -eq 'PASS' -and ($m.Id -in @('T33p','T34p'))) {
    $scaleTest = $m.Id.Substring(0,3)
    $scaleRounds = if ($m.Id -eq 'T34p') {100} else {16}
    $scalePrefix = $scaleTest.ToLowerInvariant() + '_vl128'
    & python (Join-Path $sim 'check_vl128_phy.py') $log --test-id $scaleTest --rounds $scaleRounds `
      --capture-a (Join-Path $met ($scalePrefix + '_a.hex')) `
      --capture-b (Join-Path $met ($scalePrefix + '_b.hex')) `
      --cycles-a (Join-Path $met ($scalePrefix + '_a_cycles.txt')) `
      --cycles-b (Join-Path $met ($scalePrefix + '_b_cycles.txt')) `
      --out (Join-Path $runOutput ($m.Id + '_phy_audit.json'))
    if ($LASTEXITCODE -ne 0) {
      $vd = [pscustomobject]@{ Result='FAIL'; Reason='independent128-VL PHY byte/timing audit failed'; Verdict='' }
    } else { $semanticNote = 'independent128-VL PHY byte/timing and negative-control audit passed' }
    $result = $vd.Result
  }
  if ($result -eq 'PASS') {
    $npass++; $verdict = $vd.Verdict
    if ($semanticNote -ne '') { $verdict += ' | ' + $semanticNote }
  }
  elseif ($vd.Verdict -ne '') { $verdict = $vd.Reason + ' | ' + $vd.Verdict }
  else { $verdict = $vd.Reason }
  $summary = $verdict -replace ',', ';'
  $rows.Add(($m.Id + ',' + $m.Cfg + ',' + $m.Tb + ',' + $result + ',na,' + $wall + ',' + $summary))
  [IO.File]::WriteAllLines($partialCsvPath, $rows)
  if (Test-Path -LiteralPath $log) {
    Copy-Item -LiteralPath $log -Destination (Join-Path $runOutput ($m.Tb + '.log')) -Force
  }
  $meta.tests_completed = $idx
  $meta.pass_count = $npass
  $meta.test_results += [ordered]@{ id=$m.Id; result=$result; simulator_exit_code=$rc; wall_s=$wall; console_log=[IO.Path]::GetFileName($log); reason=$vd.Reason }
  Save-RunMetadata
  Write-Output ("[" + $idx + "/" + $manifest.Count + "] " + $m.Id + " " + $m.Tb + " -> " + $result + " (" + $wall + " s) " + $verdict)
}

$csvPath = Join-Path $runOutput 'regress.csv'
[IO.File]::WriteAllLines($csvPath, $rows)
$meta.regression_result = if ($npass -eq $manifest.Count) { 'PASS' } else { 'FAIL' }
$meta.pass_count = $npass
$meta.test_count = $manifest.Count
$meta.return_code = if ($npass -eq $manifest.Count) { 0 } else { 1 }
$meta.wall_s = [math]::Round($t0.Elapsed.TotalSeconds,1)
$meta.completed_local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
$meta.current_test = $null
Save-RunMetadata
Write-Output ("REGRESS SUMMARY: " + $npass + "/" + $manifest.Count + " pass, wall_s=" + [math]::Round($t0.Elapsed.TotalSeconds,1))
Write-Output ("CSV: " + $csvPath)
$rows | Write-Output
$py = Join-Path $projectRoot 'sw\report\make_report.py'
if (Test-Path $py) {
  $metricExport = Join-Path $runOutput 'metrics'
  New-Item -ItemType Directory -Path $metricExport -Force | Out-Null
  Get-ChildItem -LiteralPath $met -File | Copy-Item -Destination $metricExport -Force
  python $py --regress $csvPath --metrics $met --out (Join-Path $metricExport 'summary.txt')
  if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: metrics report generation failed'; exit 1 }
}
if ($npass -ne $manifest.Count) { exit 1 }
exit 0
