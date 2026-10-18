param([string]$OutDir = 'out/plan_execution_20261008_t30_negative_r1')
$ErrorActionPreference = 'Stop'

$runRoot = Join-Path $PSScriptRoot $OutDir
if (Test-Path -LiteralPath $runRoot) {
  throw "Refusing to overwrite existing latency-negative evidence: $runRoot"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run_regress.ps1') `
  -Tests T30 -OutDir $OutDir
if ($LASTEXITCODE -ne 0) { throw "Positive T30 regression failed with exit code $LASTEXITCODE" }

$metaPath = Join-Path $runRoot 'run_metadata.json'
$meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
if ($meta.regression_result -ne 'PASS' -or $meta.pass_count -ne 1) {
  throw 'The baseline T30 run did not pass; refusing to interpret the negative control.'
}
$workspaceSim = Join-Path $runRoot 'workspace\sim'
$vsim = $meta.vsim_path
$negativeLog = Join-Path $runRoot 'T30_negative_console.txt'
$statusPath = Join-Path $runRoot 'T30_negative_status.json'

Push-Location $workspaceSim
try {
  & $vsim -c -lib work tb_s6_latency_negative -do 'run -all; quit -f' *> $negativeLog
  $simRc = $LASTEXITCODE
} finally {
  Pop-Location
}

$lines = @(Get-Content -LiteralPath $negativeLog -Encoding UTF8)
$failLines = New-Object 'System.Collections.Generic.List[string]'
$passLines = New-Object 'System.Collections.Generic.List[string]'
$boundFailures = New-Object 'System.Collections.Generic.List[string]'
$simErrors = New-Object 'System.Collections.Generic.List[string]'
$summary = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in $lines) {
  if ($line -match '^#?\s*T30 LATENCY FAIL\s*\(') { $failLines.Add([string]$line) }
  if ($line -match '^#?\s*T30 LATENCY PASS\b') { $passLines.Add([string]$line) }
  if ($line -match 'e2e is not strictly below 2 ms') { $boundFailures.Add([string]$line) }
  if ($line -match '^#?\s*\*\*\s*(Error|Fatal)|VSIM-ERROR') { $simErrors.Add([string]$line) }
  if ($line -match '^#?\s*Errors:\s*\d+,\s*Warnings:\s*\d+') { $summary.Add([string]$line) }
}
$hash = (Get-FileHash -LiteralPath $negativeLog -Algorithm SHA256).Hash.ToLowerInvariant()
$passed = ($simRc -eq 0 -and $failLines.Count -eq 1 -and $passLines.Count -eq 0 -and
           $boundFailures.Count -ge 1 -and $simErrors.Count -eq 0 -and
           $summary.Count -ge 1 -and $summary[-1] -match '^#?\s*Errors:\s*0,')
$state = [ordered]@{
  status = if ($passed) { 'expected_fail_confirmed' } else { 'negative_control_invalid' }
  test = 'T30 end-to-end latency negative control'
  delay_us = 2100
  total_bound_us = 2000
  simulator_exit_code = $simRc
  expected_design_failure_count = $boundFailures.Count
  verdict_lines = $failLines.ToArray()
  simulator_error_lines = $simErrors.ToArray()
  simulator_summary = $summary.ToArray()
  log = [IO.Path]::GetFileName($negativeLog)
  log_sha256 = $hash
  finished_local = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
}
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8
if (-not $passed) {
  throw "Negative latency control did not produce the expected design-level FAIL; inspect $negativeLog"
}
Write-Output "EXPECTED-FAIL-CHECK PASS: 2100 us network delay exceeded the 2000 us total bound; $statusPath"
