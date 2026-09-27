Set-Location C:\Workspace\diansai
$d = "out/arena-debug/continue2"
"==== quartus Info: Command lines ===="
Get-ChildItem "$d/sta" -Filter *.log -File | Sort-Object Name | ForEach-Object {
  $n = $_.Name
  Select-String $_.FullName -Pattern 'Info: Command:' | ForEach-Object { "{0} :: {1}" -f $n, $_.Line.Trim() }
}
"==== elapsed / processing time ===="
Get-ChildItem "$d/sta" -Filter *.log -File | Sort-Object Name | ForEach-Object {
  $n = $_.Name
  Select-String $_.FullName -Pattern 'Elapsed time:|Total CPU time' | Select-Object -Last 2 | ForEach-Object { "{0} :: {1}" -f $n, $_.Line.Trim() }
}
"==== synth rc files ===="
Get-ChildItem "$d/synth" -Filter *_rc.txt -File | Sort-Object Name | ForEach-Object { "{0} :: {1}" -f $_.Name, (Get-Content $_.FullName -Raw).Trim() }
"==== other rc files ===="
Get-ChildItem $d -Recurse -File | Where-Object { $_.Name -like "*rc*.txt" -and $_.Directory.Name -ne "synth" } | Sort-Object FullName | ForEach-Object { "{0} :: {1}" -f $_.Name, ((Get-Content $_.FullName -Raw).Trim() -replace "`r`n"," | ") }
"==== continue2 tree ===="
Get-ChildItem $d -Recurse -File | Sort-Object FullName | ForEach-Object { "{0}  {1}" -f $_.Length, $_.FullName.Replace("C:\Workspace\diansai\","").Replace("\","/") }
