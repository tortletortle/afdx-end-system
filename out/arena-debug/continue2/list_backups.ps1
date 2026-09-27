Set-Location C:\Workspace\diansai
foreach ($b in @("out/arena-debug/backup/continue_20250925","out/arena-debug/backup/continue2_20250925")) {
  "==== $b ===="
  if (Test-Path $b) {
    Get-ChildItem $b -Recurse -File | Where-Object { $_.Extension -in ".v",".ys",".md",".sdc",".edc" } |
      Sort-Object FullName | Select-Object -First 40 |
      ForEach-Object { $_.FullName.Replace("C:\Workspace\diansai\","").Replace("\","/") }
  } else { "MISSING" }
}
"==== marker check ===="
Get-ChildItem out/arena-debug/backup -Recurse -Filter AFDX_top.v -File | ForEach-Object {
  $p = $_.FullName
  $a = (Select-String $p -Pattern "rx_cfg_mem" | Measure-Object).Count
  $c = (Select-String $p -Pattern "bram_1w1r" | Measure-Object).Count
  "{0}  rx_cfg_mem={1} bram_1w1r={2}" -f $p.Replace("C:\Workspace\diansai\","").Replace("\","/"), $a, $c
}
