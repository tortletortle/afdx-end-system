# T88a chipsim smoke runner. Usage:
#   .\run_chipsim_smoke.ps1 -OutDir <dir> [-DefineRxErrorPorts]
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [switch]$DefineRxErrorPorts,
  [string]$VsimPath = ''
)
$ErrorActionPreference = 'Stop'
$sim = $PSScriptRoot
$root = Split-Path $sim -Parent
if (-not $VsimPath) {
  foreach ($c in @(
      'C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe',
      'C:\modeltech64_2020.4\win64\vsim.exe'
    )) {
    if (Test-Path -LiteralPath $c) { $VsimPath = $c; break }
  }
}
if (-not (Test-Path -LiteralPath $VsimPath)) { throw "vsim not found: $VsimPath" }

$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$workRel = 'work_chipsim'
$workAbs = Join-Path $OutDir $workRel
if (Test-Path $workAbs) { Remove-Item -Recurse -Force $workAbs }

$sources = Get-Content (Join-Path $root 'elinx\AFDX_top_sources.f') |
  Where-Object { $_ -and ($_ -notmatch '^\s*#') } |
  ForEach-Object { ($_ -replace '\\', '/').Trim() }

$files = New-Object System.Collections.Generic.List[string]
foreach ($s in $sources) { [void]$files.Add(((Join-Path $root $s) -replace '\\', '/')) }
[void]$files.Add(((Join-Path $root 'rtl\top\AFDX_top_chipsim.v') -replace '\\', '/'))
[void]$files.Add(((Join-Path $sim 'tb\tb_chipsim_smoke.v') -replace '\\', '/'))

$def = if ($DefineRxErrorPorts) { '+define+CHIPSIM_RX_ERROR_PORTS' } else { '' }
$doPath = Join-Path $OutDir 'run.do'
$logPath = Join-Path $OutDir 'vsim.log'
$outUnix = ($OutDir -replace '\\', '/')
$fileLine = ($files | ForEach-Object { '{' + $_ + '}' }) -join ' '

$lines = @(
  "cd $outUnix",
  "if {[file exists $workRel]} { file delete -force $workRel }",
  "vlib $workRel",
  "vmap work $workRel",
  "vlog -work work -sv +acc $def $fileLine",
  'if {[catch {vsim -c -t 1ps work.tb_chipsim_smoke} err]} { puts "VSIM_ELAB_FAIL: $err"; quit -code 2 }',
  'onfinish stop',
  'run -all',
  'quit -f'
)
Set-Content -LiteralPath $doPath -Value ($lines -join "`n") -Encoding ASCII

# Match run_regress.ps1: cmd /c with outer quotes so paths survive.
$cmdline = '/c ""' + $VsimPath + '" -c -do "do ' + ($doPath -replace '\\','/') + '" > "' + ($logPath -replace '\\','/') + '" 2>&1"'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = $cmdline
$psi.WorkingDirectory = $OutDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [Diagnostics.Process]::Start($psi)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not $p.WaitForExit(15000)) {
  Write-Host ("VSIM_PROGRESS elapsed_s=" + [math]::Round($sw.Elapsed.TotalSeconds,1))
  if ($sw.Elapsed.TotalSeconds -gt 600) {
    taskkill /PID $p.Id /T /F 2>$null | Out-Null
    throw 'vsim timeout 600s'
  }
}

$console = if (Test-Path $logPath) { Get-Content $logPath -Raw -ErrorAction SilentlyContinue } else { '' }
$pass = $console -match 'T88a CHIPSIM SMOKE PASS'
$fail = $console -match 'T88a CHIPSIM SMOKE FAIL'
$result = if ($pass) { 'PASS' } elseif ($fail) { 'FAIL' } else { 'UNKNOWN' }
@{
  result = $result
  vsim = $VsimPath
  define_rx_error_ports = [bool]$DefineRxErrorPorts
  exit_code = $p.ExitCode
  wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  log = $logPath
} | ConvertTo-Json | Set-Content (Join-Path $OutDir 'status.json')
Write-Output ("T88a result=$result exit=$($p.ExitCode) define_rx=$DefineRxErrorPorts wall_s=$([math]::Round($sw.Elapsed.TotalSeconds,1))")
if ($DefineRxErrorPorts -and $result -ne 'PASS') { exit 1 }
