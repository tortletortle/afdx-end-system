# eLinx behavioral sim CLI equivalent: build .do from AFDX_top_sources.f + TB, run vsim.
# Does NOT hand-edit stale gui_afdx .do. Writes .do under -OutDir.
# Simulator path via -VsimPath / ELINX_VSIM / VSIM_PATH (no hardcoded machine path required).
# ASCII-only (PS 5.1 + UTF-8 Chinese comments break param parsing).
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$TbModule = 'tb_gate_public_loopback',
  [string]$TbFile = '',
  [string]$VsimPath = '',
  [string]$SourcesF = ''
)
$ErrorActionPreference = 'Stop'
$sim = $PSScriptRoot
$root = Split-Path $sim -Parent
if (-not $SourcesF) { $SourcesF = Join-Path $root 'elinx\AFDX_top_sources.f' }
if (-not $TbFile) {
  if ($TbModule -eq 'tb_gate_public_loopback') {
    $TbFile = Join-Path $sim 'tb\tb_gate_public_loopback.v'
  } else {
    $TbFile = Join-Path $sim ('tb\' + $TbModule + '.v')
  }
}
if (-not $VsimPath) {
  foreach ($c in @(
      $env:ELINX_VSIM,
      $env:VSIM_PATH,
      'C:\modeltech64_2020.4\win64\vsim.exe',
      'C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe'
    )) {
    if ($c -and (Test-Path -LiteralPath $c)) { $VsimPath = $c; break }
  }
}
if (-not $VsimPath -or -not (Test-Path -LiteralPath $VsimPath)) {
  throw 'vsim not found; set -VsimPath or ELINX_VSIM / VSIM_PATH'
}

$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# TB looks for vec/*.hex relative to cwd (= OutDir)
$vecSrc = Join-Path $sim 'vec'
if (Test-Path $vecSrc) {
  New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'vec') | Out-Null
  Copy-Item -Force (Join-Path $vecSrc '*') (Join-Path $OutDir 'vec')
}
$workRel = 'work_elinx_behav'
$workAbs = Join-Path $OutDir $workRel
if (Test-Path $workAbs) { Remove-Item -Recurse -Force $workAbs }

$srcs = Get-Content $SourcesF | Where-Object { $_ -and ($_ -notmatch '^\s*#') } |
  ForEach-Object { ($_ -replace '\\', '/').Trim() }
$files = New-Object System.Collections.Generic.List[string]
foreach ($s in $srcs) {
  [void]$files.Add(((Join-Path $root $s) -replace '\\', '/'))
}
[void]$files.Add(($TbFile -replace '\\', '/'))

$outUnix = ($OutDir -replace '\\', '/')
$fileLine = ($files | ForEach-Object { '{' + $_ + '}' }) -join ' '
$doPath = Join-Path $OutDir 'AFDX_top_behav.do'
$logPath = Join-Path $OutDir 'vsim.log'
$batPath = Join-Path $OutDir 'run_sim.bat'

$doLines = @(
  ('cd ' + $outUnix),
  ('if {[file exists ' + $workRel + ']} { file delete -force ' + $workRel + ' }'),
  ('vlib ' + $workRel),
  ('vmap work ' + $workRel),
  ('vlog -work work -vlog01compat +acc ' + $fileLine),
  ('if {[catch {vsim -c -t 1ps work.' + $TbModule + '} err]} { puts "VSIM_ELAB_FAIL: $err"; quit -code 2 }'),
  'onfinish stop',
  'run -all',
  'quit -f'
)
Set-Content -LiteralPath $doPath -Value ($doLines -join "`n") -Encoding ASCII

$bat = @(
  '@echo off',
  'REM Prefer: powershell -File sim/run_elinx_behav.ps1 -OutDir <dir> -VsimPath <vsim>',
  ('cd /d "' + $OutDir + '"'),
  '"%ELINX_VSIM%" -c -do "do AFDX_top_behav.do" -l vsim.log'
) -join "`r`n"
Set-Content -LiteralPath $batPath -Value $bat -Encoding ASCII

$cmdline = '/c ""' + $VsimPath + '" -c -do "do ' + ($doPath -replace '\\','/') + '" > "' + ($logPath -replace '\\','/') + '" 2>&1"'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = $cmdline
$psi.WorkingDirectory = $OutDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not $p.WaitForExit(20000)) {
  Write-Host ('ELINX_BEHAV elapsed_s=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
  if ($sw.Elapsed.TotalSeconds -gt 900) {
    taskkill /PID $p.Id /T /F 2>$null | Out-Null
    throw 'elinx behav timeout 900s'
  }
}

$console = ''
if (Test-Path $logPath) { $console = Get-Content $logPath -Raw -ErrorAction SilentlyContinue }
$vlogErr = 0
if ($console -match 'Errors:\s*(\d+)') { $vlogErr = [int]$Matches[1] }
$pass = $false
$fail = $false
if ($TbModule -eq 'tb_gate_public_loopback') {
  $pass = $console -match 'T88b GATE PUBLIC LOOPBACK PASS'
  $fail = $console -match 'T88b GATE PUBLIC LOOPBACK FAIL'
} else {
  $pass = $console -match '\bPASS\b'
  $fail = $console -match '\bFAIL\b'
}
$result = 'UNKNOWN'
if ($pass -and -not $fail -and $vlogErr -eq 0) { $result = 'PASS' }
elseif ($fail -or $vlogErr -ne 0) { $result = 'FAIL' }

@{
  result = $result
  vsim = $VsimPath
  tb = $TbModule
  sources_count = $srcs.Count
  wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  exit_code = $p.ExitCode
  do_file = $doPath
  log = $logPath
  note = 'DO from AFDX_top_sources.f (same list as epr); not hand-edit of gui_afdx stale .do'
} | ConvertTo-Json | Set-Content (Join-Path $OutDir 'status.json')

Write-Output ('ELINX_BEHAV result=' + $result + ' sources=' + $srcs.Count + ' wall_s=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
if ($result -ne 'PASS') { exit 1 }
