# Run T91 (tb_gate_t91_throughput) against a Quartus functional VO on ModelSim SE.
# Usage:
#   .\run_gate_t91.ps1 -VoPath <AFDX_top.vo> -OutDir <dir> [-VsimPath <modelsim SE vsim>]
# Requires modelsim.ini mapping elinx_lib (copied from archive run_v2 by default).
# ASCII-only. Clone of run_gate_t88b.ps1 (VoptFlow=0, suppress 12110).
param(
  [Parameter(Mandatory = $true)][string]$VoPath,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$VsimPath = '',
  [string]$ModelsimIni = '',
  [string]$TbFile = '',
  [string]$ElinxLib = ''
)
$ErrorActionPreference = 'Stop'
$sim = $PSScriptRoot
$root = Split-Path $sim -Parent
if (-not $TbFile) { $TbFile = Join-Path $sim 'tb\tb_gate_t91_throughput.v' }
if (-not $VsimPath) {
  foreach ($c in @(
      $env:MODELSIM_SE_VSIM,
      'C:\modeltech64_2020.4\win64\vsim.exe'
    )) {
    if ($c -and (Test-Path -LiteralPath $c)) { $VsimPath = $c; break }
  }
}
if (-not (Test-Path -LiteralPath $VsimPath)) { throw "ModelSim SE vsim not found: $VsimPath" }
if (-not (Test-Path -LiteralPath $VoPath)) { throw "VO missing: $VoPath" }
if (-not $ModelsimIni) {
  $ModelsimIni = Join-Path $root 'out\archive_20261016_203815\plan_execution_20261008_r1\quartus_gate\run_v2\modelsim.ini'
}
if (-not (Test-Path -LiteralPath $ModelsimIni)) { throw "modelsim.ini missing: $ModelsimIni" }
if (-not $ElinxLib) {
  $localLib = Join-Path $root 'out\elinx_lib'
  if (Test-Path -LiteralPath $localLib) { $ElinxLib = $localLib }
  else { $ElinxLib = 'C:\Program Files (x86)\eHiWay\eLinx3.0\Simulation\elinx_lib' }
}

$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Force VoptFlow=0: SE 2020.4 vopt hangs (CPU=0) on this host for AFDX VO (2026-10-23).
$iniText = Get-Content -LiteralPath $ModelsimIni -Raw
$iniText = $iniText -replace 'elinx_lib\s*=\s*.+', ('elinx_lib = ' + ($ElinxLib -replace '\\', '/'))
if ($iniText -match 'VoptFlow\s*=') {
  $iniText = $iniText -replace 'VoptFlow\s*=\s*\d+', 'VoptFlow = 0'
} else {
  $iniText = $iniText + "`nVoptFlow = 0`n"
}
Set-Content -LiteralPath (Join-Path $OutDir 'modelsim.ini') -Value $iniText -Encoding ASCII

Copy-Item -Force $VoPath (Join-Path $OutDir 'AFDX_top.vo')
# payload golden for TB $readmemh("vec/t91_payload.hex")
$vecSrc = Join-Path $sim 'vec\t91_payload.hex'
$vecDstDir = Join-Path $OutDir 'vec'
New-Item -ItemType Directory -Force -Path $vecDstDir | Out-Null
if (-not (Test-Path -LiteralPath $vecSrc)) { throw "missing $vecSrc — run python tools/gen_t91_payload_vec.py" }
Copy-Item -Force $vecSrc (Join-Path $vecDstDir 't91_payload.hex')

$voSha = (Get-FileHash -LiteralPath $VoPath -Algorithm SHA256).Hash.ToLowerInvariant()
$tbSha = (Get-FileHash -LiteralPath $TbFile -Algorithm SHA256).Hash.ToLowerInvariant()
$workRel = 'work_gate'
$workAbs = Join-Path $OutDir $workRel
if (Test-Path $workAbs) { Remove-Item -Recurse -Force $workAbs }

$outUnix = ($OutDir -replace '\\', '/')
$voUnix = ($OutDir + '/AFDX_top.vo') -replace '\\', '/'
$tbUnix = ($TbFile -replace '\\', '/')
$doPath = Join-Path $OutDir 'run_gate.do'
$logPath = Join-Path $OutDir 'vsim.log'

# suppress 12110 required when VoptFlow=0 (else vlog treats as Error).
# cwd = OutDir so TB fopen("t91_metrics.csv") / summary land here.
$doLines = @(
  ('cd ' + $outUnix),
  ('if {[file exists ' + $workRel + ']} { file delete -force ' + $workRel + ' }'),
  ('vlib ' + $workRel),
  ('vmap work ' + $workRel),
  ('vlog -suppress 12110 -work work +acc=n {' + $voUnix + '}'),
  ('vlog -suppress 12110 -work work +acc=n {' + $tbUnix + '}'),
  'puts "ELAB_START"',
  'if {[catch {vsim -suppress 12110 -c -t 1ps -L elinx_lib work.tb_gate_t91_throughput} err]} { puts "VSIM_ELAB_FAIL: $err"; quit -code 2 }',
  'puts "ELAB_DONE"',
  'onfinish stop',
  'run -all',
  'quit -f'
)
Set-Content -LiteralPath $doPath -Value ($doLines -join "`n") -Encoding ASCII

$cmdline = '/c ""' + $VsimPath + '" -c -do "do ' + ($doPath -replace '\\','/') + '" > "' + ($logPath -replace '\\','/') + '" 2>&1"'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = $cmdline
$psi.WorkingDirectory = $OutDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not $p.WaitForExit(30000)) {
  Write-Host ('GATE_T91 elapsed_s=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
  if ($sw.Elapsed.TotalSeconds -gt 28800) {
    taskkill /PID $p.Id /T /F 2>$null | Out-Null
    throw 'gate T91 timeout 8h'
  }
}

$console = ''
if (Test-Path $logPath) { $console = Get-Content $logPath -Raw -ErrorAction SilentlyContinue }
$pass = $console -match 'T91 GATE THROUGHPUT PASS'
$fail = $console -match 'T91 GATE THROUGHPUT FAIL'
$result = if ($pass -and -not $fail) { 'PASS' } elseif ($fail) { 'FAIL' } else { 'UNKNOWN' }
$status = @{
  result = $result
  vsim = $VsimPath
  vo_sha256 = $voSha
  tb_sha256 = $tbSha
  wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  exit_code = $p.ExitCode
  elab = 'VoptFlow=0 + suppress 12110 (vopt hung on this host)'
  nvl_default = 16
  rounds_default = 3
  claim_allowed_if_pass = 'current-source Quartus functional VO public-port gate throughput T91 (NVL=16 ROUNDS=3 steady rounds 2-3) tx_a/tx_b/rx_dedup >=100 Mbps; ROUNDS=1 runs are probe-only (not P)'
  forbidden = @('gate full140', 'SDF/timing sim', 'eLinx native netlist PASS', 'T91_NVL=128', 'claim ROUNDS=1 probe as P', 'claim as original T00-T22 matrix')
}

$status | ConvertTo-Json | Set-Content (Join-Path $OutDir 'simulation_status.json')
Write-Output ('GATE_T91 result=' + $result + ' wall_s=' + $status.wall_s)
if ($result -ne 'PASS') { exit 1 }
