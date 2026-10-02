# =====================================================================
# regress_verdict.ps1 - strict per-test verdict for run_regress.ps1
# (audit 20260928 A04: the old runner kept only the LAST line containing
#  PASS|FAIL, so "FAIL ... PASS" or "** Error ... PASS" could go green).
#
# A test is PASS only if ALL of the following hold:
#   1. vsim rc == 0 (rc -1 = runner timeout)
#   2. exactly ONE verdict line  "# T<nn>... PASS|FAIL ..."  (case-sensitive)
#   3. that line's T<nn> family equals the manifest id's family
#      (T12c -> T12, T09ps -> T09, T08f -> T08 ...)
#   4. that line contains PASS
#   5. no line anywhere contains upper-case FAIL
#   6. no Questa "** Error" / "** Fatal" line, no "VSIM-ERROR"
#   7. the session end summary "# Errors: N, Warnings: M" exists, N == 0
#      (missing summary = simulator died / did not reach quit)
# Expected-negative runs (mutants, tightened limits) are judged by the
# same function and simply expect Result == 'FAIL'.
# ASCII-only on purpose (week0 pitfall #3).
# =====================================================================
function Get-TestVerdict {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [AllowNull()][AllowEmptyCollection()][string[]]$Lines,
    [int]$Rc
  )
  $mk = { param($r, $why, $v) [pscustomobject]@{ Result = $r; Reason = $why; Verdict = $v } }
  if ($Rc -eq -1) { return (& $mk 'FAIL' 'TIMEOUT(600s)' '') }
  if ($null -eq $Lines -or $Lines.Count -eq 0) { return (& $mk 'FAIL' ('empty log, vsim rc=' + $Rc) '') }

  $fam = ''
  if ($Id -match '^(T\d\d)') { $fam = $Matches[1] }

  $verdicts = New-Object System.Collections.Generic.List[string]
  $vfam = New-Object System.Collections.Generic.List[string]
  $nFail = 0; $nErr = 0; $summaryErr = $null
  foreach ($raw in $Lines) {
    $l = "$raw"
    if ($l -cmatch '^#?\s*(T\d\d)[A-Za-z]*\s.*\b(PASS|FAIL)\b') {
      $vfam.Add($Matches[1]); $verdicts.Add($l.Trim())
    }
    if ($l -cmatch '\bFAIL') { $nFail++ }
    if ($l -match '^#?\s*\*\*\s*(Error|Fatal)' -or $l -match 'VSIM-ERROR') { $nErr++ }
    if ($l -match '^#?\s*Errors:\s*(\d+),\s*Warnings:\s*\d+') { $summaryErr = [int]$Matches[1] }
  }
  $v = if ($verdicts.Count -gt 0) { $verdicts[$verdicts.Count - 1] } else { '' }

  if ($verdicts.Count -eq 0) { return (& $mk 'FAIL' ('no verdict line, vsim rc=' + $Rc) '') }
  if ($verdicts.Count -gt 1) { return (& $mk 'FAIL' ('multiple verdict lines (' + $verdicts.Count + ')') $v) }
  if ($fam -eq '' -or $vfam[0] -ne $fam) { return (& $mk 'FAIL' ('verdict family ' + $vfam[0] + ' does not match id ' + $Id) $v) }
  if ($nFail -gt 0) { return (& $mk 'FAIL' ('FAIL text in log (' + $nFail + ' line(s))') $v) }
  if ($nErr -gt 0) { return (& $mk 'FAIL' ('simulator Error/Fatal (' + $nErr + ' line(s))') $v) }
  if ($Rc -ne 0) { return (& $mk 'FAIL' ('vsim rc=' + $Rc) $v) }
  if ($null -eq $summaryErr) { return (& $mk 'FAIL' 'no simulator end summary (Errors: N)' $v) }
  if ($summaryErr -ne 0) { return (& $mk 'FAIL' ('simulator reported Errors: ' + $summaryErr) $v) }
  if ($v -cnotmatch '\bPASS\b') { return (& $mk 'FAIL' 'verdict line is not PASS' $v) }
  return (& $mk 'PASS' '' $v)
}
