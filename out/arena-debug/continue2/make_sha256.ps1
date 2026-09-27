# continue2：对本轮所有证据与被改文件生成 SHA-256 清单
Set-Location C:\Workspace\diansai
$out = "out/arena-debug/continue2/SHA256SUMS.txt"
$targets = @(
  "rtl/top/AFDX_top.v","rtl/common/bram_sdp.v",
  "elinx/prj/AFDX_top_synth.ys","elinx/prj/AFDX_top_synth_bram.ys",
  "elinx/sdc/AFDX_top.sdc","elinx/sdc/AFDX_top.edc",
  "elinx/prj/quartus/AFDX_top.qpf","elinx/prj/quartus/AFDX_top.qsf",
  "elinx/prj/quartus/mk_project.tcl","elinx/prj/quartus/sta_post_map.tcl",
  "elinx/prj/quartus/sta_summary.tcl",
  "sim/out/regress.csv","sim/out/compile_console.txt",
  "out/arena-debug/fixes.patch",
  "out/arena-debug/DIANSAI-REPORT.md",
  "out/arena-debug/finalize/sta/README.md"
)
# doc/*.md enumerated instead of hard-coded: the filenames are Chinese and this
# script must stay pure ASCII (PS 5.1 parses BOM-less UTF-8 as GBK).
foreach ($f in (Get-ChildItem doc -Filter *.md -File | Sort-Object Name)) {
  $targets += ("doc/" + $f.Name)
}
$lines = @()
foreach ($t in $targets) {
  if (Test-Path $t) { $lines += ("{0}  {1}" -f (Get-FileHash $t -Algorithm SHA256).Hash, $t) }
  else { $lines += ("MISSING  {0}" -f $t) }
}
Get-ChildItem out/arena-debug/continue2 -Recurse -File |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object FullName |
  ForEach-Object {
    $rel = $_.FullName.Replace("C:\Workspace\diansai\","").Replace("\","/")
    $lines += ("{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $rel)
  }
# UTF-8 without BOM: the doc/ filenames are Chinese and -Encoding ascii would
# write them as "???" and make the manifest useless for those entries.
[IO.File]::WriteAllLines((Join-Path (Get-Location).Path $out), $lines, (New-Object Text.UTF8Encoding($false)))
"entries=" + $lines.Count
