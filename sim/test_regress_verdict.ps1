# =====================================================================
# test_regress_verdict.ps1 - self-test of regress_verdict.ps1 (audit A04)
# Usage (from sim/):
#   powershell -ExecutionPolicy Bypass -File .\test_regress_verdict.ps1
#   ... -LogDir ..\out\arena-debug\continue12\tests\full56
#       (also re-judges every manifest test's archived console log and
#        requires all of them to stay PASS under the strict rules)
# Exit 0 only if every synthetic case gives the expected verdict (and,
# with -LogDir, every archived log is PASS).  ASCII-only.
# =====================================================================
param([string]$LogDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'regress_verdict.ps1')
function if2($c, $a, $b) { if ($c) { $a } else { $b } }

$okEnd = @('# ** Note: $finish    : tb/x.v(1)', '# End time: 00:00:00', '# Errors: 0, Warnings: 1')
$cases = @(
  @{ n='pass only';                id='T10'; rc=0;  exp='PASS'; L=@('# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='FAIL then PASS';           id='T10'; rc=0;  exp='FAIL'; L=@('# T10 TOP RM FAIL (errors=1)', '# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='Error then PASS';          id='T10'; rc=0;  exp='FAIL'; L=@('# ** Error: assertion failed', '# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='Fatal then PASS';          id='T10'; rc=0;  exp='FAIL'; L=@('# ** Fatal: out of range', '# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='PASS then FAIL';           id='T10'; rc=0;  exp='FAIL'; L=@('# T10 TOP RM PASS (ok)', '# T10 TOP RM FAIL (late)') + $okEnd },
  @{ n='PASS but rc=1';            id='T10'; rc=1;  exp='FAIL'; L=@('# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='timeout';                  id='T10'; rc=-1; exp='FAIL'; L=@('# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='no verdict line';          id='T10'; rc=0;  exp='FAIL'; L=@('# some text') + $okEnd },
  @{ n='two PASS verdicts';        id='T10'; rc=0;  exp='FAIL'; L=@('# T10 TOP RM PASS (a)', '# T10 TOP RM PASS (b)') + $okEnd },
  @{ n='wrong test family';        id='T10'; rc=0;  exp='FAIL'; L=@('# T11 TOP PORT PASS (ok)') + $okEnd },
  @{ n='no end summary';           id='T10'; rc=0;  exp='FAIL'; L=@('# T10 TOP RM PASS (ok)') },
  @{ n='summary Errors: 2';        id='T10'; rc=0;  exp='FAIL'; L=@('# T10 TOP RM PASS (ok)', '# Errors: 2, Warnings: 0') },
  @{ n='empty log';                id='T10'; rc=0;  exp='FAIL'; L=@() },
  @{ n='VSIM-ERROR';               id='T10'; rc=0;  exp='FAIL'; L=@('VSIM-ERROR: design not found', '# T10 TOP RM PASS (ok)') + $okEnd },
  @{ n='FAIL inside err text';     id='T13'; rc=0;  exp='FAIL'; L=@('#   [err] T13 t=1: FAIL x', '# T13 END-TO-END LATENCY PASS (ok)') + $okEnd },
  @{ n='family alias T12c->T12';   id='T12c'; rc=0; exp='PASS'; L=@('# T12 LOOKUP PASS (case=1)') + $okEnd },
  @{ n='family alias T09ps->T09'; id='T09ps'; rc=0; exp='PASS'; L=@('# T09p RX-IC PRESSURE PASS (N=1)') + $okEnd },
  @{ n='metric lines ignored';     id='T13'; rc=0;  exp='PASS'; L=@('# T13METRIC case=1 total_ns=1', '# T13 END-TO-END LATENCY PASS (ok)') + $okEnd },
  @{ n='lower-case fail word ok';  id='T10'; rc=0;  exp='PASS'; L=@('#   info: no failures seen', '# T10 TOP RM PASS (ok)') + $okEnd }
)
$bad = 0
foreach ($c in $cases) {
  $r = Get-TestVerdict -Id $c.id -Lines ([string[]]$c.L) -Rc $c.rc
  $ok = ($r.Result -eq $c.exp)
  if (-not $ok) { $bad++ }
  Write-Output ((if2 $ok 'ok  ' 'BAD ') + $c.n + ' -> ' + $r.Result + ' ' + $r.Reason)
}
Write-Output ('VERDICT-SELFTEST synthetic: ' + ($cases.Count - $bad) + '/' + $cases.Count + ' as expected')

if ($LogDir -ne '') {
  $man = @()
  foreach ($line in (Get-Content (Join-Path $PSScriptRoot 'tests.manifest') -Encoding UTF8)) {
    $t = "$line".Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $man += ($t -split '\s+')[0]
  }
  $rbad = 0
  foreach ($id in $man) {
    $f = Join-Path $LogDir ($id + '_console.txt')
    if (-not (Test-Path $f)) { $rbad++; Write-Output ('BAD  replay ' + $id + ': log missing'); continue }
    $r = Get-TestVerdict -Id $id -Lines ([string[]](Get-Content $f -Encoding UTF8)) -Rc 0
    if ($r.Result -ne 'PASS') { $rbad++; Write-Output ('BAD  replay ' + $id + ': ' + $r.Reason) }
  }
  Write-Output ('VERDICT-SELFTEST replay: ' + ($man.Count - $rbad) + '/' + $man.Count + ' archived logs PASS under strict rules (' + $LogDir + ')')
  $bad += $rbad
}
if ($bad -ne 0) { exit 1 }
exit 0
