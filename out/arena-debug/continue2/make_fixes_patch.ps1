# =====================================================================
# continue2 patch generator.  ASCII-only on purpose (PS 5.1 reads BOM-less
# UTF-8 .ps1 as GBK; Chinese literals would corrupt the script).  Chinese
# doc filenames are handled by enumerating the backup directory instead of
# hard-coding names.
#
# Patch A -> out/arena-debug/fixes.patch
#   baseline: out/arena-debug/backup/continue2_20250925  (state at the start
#   of THIS round).  Contains this round's source/script/doc changes only.
#
# Patch B -> out/arena-debug/continue2/continue2_full_rtl.patch
#   baseline: out/arena-debug/backup/continue_20250925/session_20260925_0432
#   (RTL before the whole continue2 rx_cfg BRAM rework).  Contains the
#   complete RTL delta that takes top-level synthesis from FAIL to rc=0.
#
# Generated artefacts (logs, UCDB, netlist, .rpt) are deliberately NOT in
# either patch.
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-Location C:\Workspace\diansai
$root = (Get-Location).Path
# Scratch trees MUST live outside the git work tree: "git apply" run from a
# subdirectory of a repository silently skips patch paths that fall outside
# that subdirectory, which would make the verification vacuously pass.
$work = Join-Path $env:TEMP "diansai_continue2_patchwork"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }

function Copy-Rel {
  param([string]$SrcFile, [string]$DstRoot, [string]$Rel)
  $dst = Join-Path $DstRoot $Rel
  $dir = Split-Path $dst -Parent
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $SrcFile -Destination $dst -Force
}

function Make-Patch {
  param([string]$Tag, [hashtable]$Map, [string]$OutFile, [string[]]$Header)
  $before = Join-Path $work "$Tag/before"
  $after  = Join-Path $work "$Tag/after"
  New-Item -ItemType Directory -Force -Path $before, $after | Out-Null
  foreach ($rel in $Map.Keys) {
    $src = $Map[$rel]
    if ($src -ne $null -and (Test-Path -LiteralPath $src)) { Copy-Rel $src $before $rel }
    if (Test-Path -LiteralPath $rel) { Copy-Rel $rel $after $rel }
  }
  # PowerShell's ">" would re-encode git's output as UTF-16; route the
  # redirection through cmd.exe so the raw byte stream is preserved.
  Push-Location (Join-Path $work $Tag)
  $raw = "$root\$OutFile.raw"
  $cl  = 'git -c core.quotepath=false -c core.autocrlf=false diff --no-index --text -- before after > "{0}" 2>nul' -f $raw
  & cmd /c $cl
  Pop-Location
  # Byte-level rewrite of the a/before -> a/ prefixes.  The tracked docs mix
  # clean UTF-8 (new sections) with legacy GBK bytes (old sections), so any
  # text round-trip through UTF-8 would mangle them and the patch would no
  # longer apply.  ISO-8859-1 is a lossless byte<->char mapping.
  # Only header lines may be rewritten: a naive global replace would also hit
  # payload lines (this very script quotes those prefixes) and corrupt them.
  $enc   = [Text.Encoding]::GetEncoding(28591)
  $txt   = $enc.GetString([IO.File]::ReadAllBytes("$root\$OutFile.raw"))
  $sp    = 'a/' + 'before/'
  $dp    = 'b/' + 'after/'
  $lines = $txt -split "`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if     ($l.StartsWith('diff --git ')) { $lines[$i] = $l.Replace($sp, 'a/').Replace($dp, 'b/') }
    elseif ($l.StartsWith('--- '))        { $lines[$i] = $l.Replace($sp, 'a/') }
    elseif ($l.StartsWith('+++ '))        { $lines[$i] = $l.Replace($dp, 'b/') }
  }
  $txt = $lines -join "`n"
  if ($Header) { $txt = (($Header | ForEach-Object { "# " + $_ }) -join "`n") + "`n#`n" + $txt }
  [IO.File]::WriteAllBytes("$root\$OutFile", $enc.GetBytes($txt))
  Remove-Item "$root\$OutFile.raw" -Force
  $n = ([regex]::Matches($txt, '(?m)^diff --git ')).Count
  "{0}: {1} files, {2} bytes, sha256={3}" -f $OutFile, $n, (Get-Item $OutFile).Length,
    (Get-FileHash $OutFile -Algorithm SHA256).Hash
}

# ---------------- Patch A : this round ----------------
$A = "out/arena-debug/backup/continue2_20250925"
$mapA = @{}
$mapA["rtl/top/AFDX_top.v"] = "$A/rtl/top/AFDX_top.v"
$mapA["out/arena-debug/DIANSAI-REPORT.md"] = "$A/out/arena-debug/DIANSAI-REPORT.md"
# Not present in this round's backup because the interrupted session never touched
# it; its pre-edit state is the copy kept by the previous round's backup.
$mapA["out/arena-debug/finalize/sta/README.md"] = "out/arena-debug/backup/continue_20250925/session_20260925_0432/out/arena-debug/finalize/sta/README.md"
foreach ($f in Get-ChildItem "$A/doc" -Filter *.md -File) {
  $mapA["doc/" + $f.Name] = $f.FullName
}
# new files this round (no baseline copy -> shown as additions)
$newFiles = @(
  "elinx/prj/AFDX_top_synth_bram.ys",
  "elinx/sdc/AFDX_top.sdc",
  "elinx/prj/quartus/mk_project.tcl",
  "elinx/prj/quartus/sta_post_map.tcl",
  "elinx/prj/quartus/sta_summary.tcl",
  "out/arena-debug/continue2/SYNTH.md",
  "out/arena-debug/continue2/STA.md",
  "out/arena-debug/continue2/COVERAGE.md",
  "out/arena-debug/continue2/MANAGEMENT-SCOPE.md",
  "out/arena-debug/continue2/COMMANDS.md",
  "out/arena-debug/continue2/make_sha256.ps1",
  "out/arena-debug/continue2/make_fixes_patch.ps1",
  "out/arena-debug/continue2/list_backups.ps1",
  "out/arena-debug/continue2/extract_cmds.ps1",
  "out/arena-debug/continue2/synth/run_syn.ps1",
  "out/arena-debug/continue2/synth/inspect_log.ps1",
  "out/arena-debug/continue2/synth/mem_report.ps1",
  "out/arena-debug/continue2/synth/probe_writers.ys",
  "out/arena-debug/continue2/sta/list_parts.tcl",
  "out/arena-debug/continue2/coverage/run_full_cov.ps1",
  "out/arena-debug/continue2/coverage/run_full_cov.tcl",
  "out/arena-debug/continue2/coverage/compile_full_cov.tcl"
)
foreach ($f in $newFiles) { $mapA[$f] = $null }
$hdrA = @(
  "fixes.patch - MISSION-CONTINUE2 (2026-09-25): source/script/doc changes of THIS round.",
  "",
  "BASELINE: out/arena-debug/backup/continue2_20250925/  - the working tree as handed over",
  "at the start of this round: rx_cfg already converted to bram_1w1r by the previous,",
  "interrupted session, but with the host-readback defect still present and 5 testbenches",
  "failing.  Exception: out/arena-debug/finalize/sta/README.md comes from",
  "backup/continue_20250925/session_20260925_0432/ (the interrupted session never copied it).",
  "",
  "APPLY :  git apply    out/arena-debug/fixes.patch",
  "REVERT:  git apply -R out/arena-debug/fixes.patch   -> back to the baseline above,",
  "                                                       NOT back to git HEAD.",
  "",
  "SCOPE: RTL, synthesis/STA scripts, constraints and documentation only.  Generated",
  "artefacts (logs, *.ucdb, the 49 MB netlist, *.rpt, Quartus db/) are deliberately",
  "excluded; they are archived under out/arena-debug/continue2/ instead.",
  "",
  "For the COMPLETE RTL delta that takes top-level synthesis from FAIL to rc=0 - i.e.",
  "including the previous session's rx_cfg BRAM rework - see",
  "out/arena-debug/continue2/continue2_full_rtl.patch.",
  "",
  "Both patches were verified by replaying them onto a copy of their own baseline with",
  "git apply and byte-comparing the result against the current tree:",
  "out/arena-debug/continue2/patch_verify.log."
)
Make-Patch -Tag "A" -Map $mapA -OutFile "out/arena-debug/fixes.patch" -Header $hdrA

# ---------------- Patch B : full continue2 RTL delta ----------------
$B = "out/arena-debug/backup/continue_20250925/session_20260925_0432"
$mapB = @{}
$mapB["rtl/top/AFDX_top.v"]      = "$B/rtl/top/AFDX_top.v"
$mapB["rtl/common/bram_sdp.v"]   = "$B/rtl/common/bram_sdp.v"
$mapB["elinx/prj/AFDX_top_synth.ys"] = "$B/elinx/prj/AFDX_top_synth.ys"
$mapB["elinx/prj/AFDX_top_synth_bram.ys"] = $null
$hdrB = @(
  "continue2_full_rtl.patch - COMPLETE RTL delta of the rx_cfg BRAM rework plus this",
  "round's host-readback fix.  This is the change that turns top-level eLinx synthesis",
  "from 'OPT_MUXTREE: bad allocation' into rc=0.",
  "",
  "BASELINE: out/arena-debug/backup/continue_20250925/session_20260925_0432/",
  "          (rtl/top/AFDX_top.v with 9 x rx_cfg_mem and no bram_1w1r)",
  "",
  "Contents: rtl/top/AFDX_top.v, rtl/common/bram_sdp.v, elinx/prj/AFDX_top_synth_bram.ys.",
  "elinx/prj/AFDX_top_synth.ys is unchanged against this baseline and therefore absent.",
  "",
  "APPLY :  git apply    out/arena-debug/continue2/continue2_full_rtl.patch",
  "REVERT:  git apply -R out/arena-debug/continue2/continue2_full_rtl.patch"
)
Make-Patch -Tag "B" -Map $mapB -OutFile "out/arena-debug/continue2/continue2_full_rtl.patch" -Header $hdrB

# ---------------- verification: apply each patch to its own baseline ----------------
foreach ($t in @(@("A","out/arena-debug/fixes.patch"), @("B","out/arena-debug/continue2/continue2_full_rtl.patch"))) {
  $tag = $t[0]; $pf = $t[1]
  $chk = Join-Path $work "verify_$tag"
  Copy-Item -Path (Join-Path $work "$tag/before") -Destination $chk -Recurse -Force
  Push-Location $chk
  & git -c core.quotepath=false -c core.autocrlf=false apply --whitespace=nowarn "$root\$pf" 2>&1 | Out-Null
  $rc = $LASTEXITCODE
  Pop-Location
  & git -c core.quotepath=false -c core.autocrlf=false diff --no-index --quiet -- $chk (Join-Path $work "$tag/after") 2>$null
  $rc2 = $LASTEXITCODE
  "verify_{0}: git_apply_rc={1} (0=applied) byte_identical_to_after_rc={2} (0=identical)" -f $tag, $rc, $rc2
  if ($rc2 -ne 0) {
    "  --- residual differences (stat) ---"
    & git -c core.quotepath=false -c core.autocrlf=false diff --no-index --stat -- $chk (Join-Path $work "$tag/after") 2>$null
  }
}
