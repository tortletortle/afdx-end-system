# Run T88b (tb_gate_public_loopback) against a Quartus functional VO on ModelSim SE.
# Usage:
#   .\run_gate_t88b.ps1 -VoPath <AFDX_top.vo> -OutDir <dir> [-VsimPath <modelsim SE vsim>]
# Requires modelsim.ini mapping elinx_lib (copied from archive run_v2 by default).
# ASCII-only.
param(
  [Parameter(Mandatory = $true)][string]$VoPath,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$VsimPath = '',
  [string]$ModelsimIni = '',
  [string]$TbFile = ''
)
$ErrorActionPreference = 'Stop'
$sim = $PSScriptRoot
$root = Split-Path $sim -Parent
if (-not $TbFile) { $TbFile = Join-Path $sim 'tb\tb_gate_public_loopback.v' }
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

$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item -Force $ModelsimIni (Join-Path $OutDir 'modelsim.ini')
Copy-Item -Force $VoPath (Join-Path $OutDir 'AFDX_top.vo')
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'vec') | Out-Null
Copy-Item -Force (Join-Path $sim 'vec\t88b_payload32.hex') (Join-Path $OutDir 'vec\')

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

# Functional VO: compile VO + TB; map work; +acc=n for speed (prior dual-net gate precedent).
$doLines = @(
  ('cd ' + $outUnix),
  ('if {[file exists ' + $workRel + ']} { file delete -force ' + $workRel + ' }'),
  ('vlib ' + $workRel),
  ('vmap work ' + $workRel),
  ('vlog -work work +acc=n {' + $voUnix + '}'),
  ('vlog -work work +acc=n {' + $tbUnix + '}'),
  'if {[catch {vsim -c -t 1ps -L elinx_lib -voptargs=+acc=n work.tb_gate_public_loopback} err]} { puts "VSIM_ELAB_FAIL: $err"; quit -code 2 }',
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
  Write-Host ('GATE_T88b elapsed_s=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
  if ($sw.Elapsed.TotalSeconds -gt 28800) {
    taskkill /PID $p.Id /T /F 2>$null | Out-Null
    throw 'gate T88b timeout 8h'
  }
}

$console = ''
if (Test-Path $logPath) { $console = Get-Content $logPath -Raw -ErrorAction SilentlyContinue }
$pass = $console -match 'T88b GATE PUBLIC LOOPBACK PASS'
$fail = $console -match 'T88b GATE PUBLIC LOOPBACK FAIL'
$s1 = if ($console -match 'GATE_S1 PASS') { 'PASS' } elseif ($console -match 'GATE_S1 FAIL') { 'FAIL' } else { 'UNKNOWN' }
$s2 = if ($console -match 'GATE_S2 PASS') { 'PASS' } elseif ($console -match 'GATE_S2 FAIL') { 'FAIL' } else { 'UNKNOWN' }
$s3 = if ($console -match 'GATE_S3 PASS') { 'PASS' } elseif ($console -match 'GATE_S3 NOT_PASS') { 'FAIL' } else { 'UNKNOWN' }
# Overall PASS tracks S1+S2 only; S3 is reported separately (S3 fail does not revoke S1/S2 P).
$result = if ($pass -and -not $fail) { 'PASS' } elseif ($fail) { 'FAIL' } else { 'UNKNOWN' }
$status = @{
  result = $result
  gate_s1 = $s1
  gate_s2 = $s2
  gate_s3 = $s3
  vsim = $VsimPath
  vo_sha256 = $voSha
  tb_sha256 = $tbSha
  wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  exit_code = $p.ExitCode
  claim_allowed_if_pass = 'current-source Quartus functional VO public-port dual-net single-frame loopback S1+S2 PASS; S3 see gate_s3 field'
  forbidden = @('gate full140', 'SDF/timing sim', 'eLinx native netlist PASS', 'S3 fail revokes S1/S2')
}
$status | ConvertTo-Json | Set-Content (Join-Path $OutDir 'simulation_status.json')
Write-Output ('GATE_T88b result=' + $result + ' s3=' + $s3 + ' wall_s=' + $status.wall_s)
if ($result -ne 'PASS') { exit 1 }
