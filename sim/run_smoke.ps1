# Fixed smoke subset for judge/demo entry. Calls run_regress.ps1 -Tests.
# Subset sized from post_fix4_full140 wall times to keep total <= ~20 min.
# Smoke != full 140. ASCII-only.
param(
  [string]$OutDir = '',
  [string]$VsimPath = ''
)
$ErrorActionPreference = 'Stop'
$sim = $PSScriptRoot
# post_fix4 walls (s): T00 19.8 T01 362.2 T03 18.6 T04 25.2 T08e 33 T09 16.9
# T10 22.3 T11 20.2 T22g 21.9 T41 18 T42 40.1 T43 56.5 T16u 19.1 T16a 147.8
# Sum plan set ~821s (~13.7 min) + T88b ~31s => under 20 min.
# T88 replaces T88b in judge smoke (demo steps 1-4). T88b remains gate/RTL entry.
$Tests = 'T00,T01,T03,T04,T08e,T09,T10,T11,T22g,T41,T42,T43,T16u,T16a,T88'
if (-not $OutDir) {
  $OutDir = Join-Path $sim ('out\smoke_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$args = @('-Tests', $Tests, '-OutDir', $OutDir)
if ($VsimPath) { $args += @('-VsimPath', $VsimPath) }
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sim 'run_regress.ps1') @args
$rc = $LASTEXITCODE
$summary = Join-Path $OutDir 'SMOKE_SUMMARY.md'
$csv = Join-Path $OutDir 'regress.csv'
$lines = @(
  '# SMOKE_SUMMARY',
  '',
  '> Smoke != full regression. Full 140 evidence: `sim/out/post_fix4_full140_20261018_011708/`.',
  '',
  ('- Tests: `' + $Tests + '`'),
  ('- OutDir: `' + $OutDir + '`'),
  ('- run_regress exit: ' + $rc),
  ''
)
if (Test-Path $csv) {
  $lines += '| test_id | result | wall_s |'
  $lines += '|---|---|---|'
  Import-Csv $csv | ForEach-Object {
    $lines += ('| ' + $_.test_id + ' | ' + $_.result + ' | ' + $_.wall_s + ' |')
  }
  $pass = @(Import-Csv $csv | Where-Object { $_.result -eq 'PASS' }).Count
  $n = @(Import-Csv $csv).Count
  $lines += ''
  $lines += ('**Result: ' + $pass + '/' + $n + ' PASS**')
} else {
  $lines += 'regress.csv missing (compile/audit failure before tests).'
}
Set-Content -LiteralPath $summary -Value ($lines -join "`n") -Encoding UTF8
Write-Output ('SMOKE_SUMMARY written: ' + $summary)
exit $rc
