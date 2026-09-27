param([Parameter(Mandatory=$true)][string]$Log)
Set-Location C:\Workspace\diansai
$all = Get-Content $Log
"LINES=" + $all.Count
"ERROR=" + ((Select-String $Log -Pattern '^ERROR').Count)
"WARNING=" + ((Select-String $Log -Pattern '^Warning').Count)
"SUCCESS_BANNER=" + ((Select-String $Log -Pattern 'Yosys execute success!').Count)
"SHA256=" + (Get-FileHash $Log -Algorithm SHA256).Hash
"---- top module stat ----"
$m = Select-String $Log -Pattern '^=== \\AFDX_top ===' | Select-Object -Last 1
if ($m) { $all[($m.LineNumber-1)..([Math]::Min($m.LineNumber+40,$all.Count-1))] } else { "AFDX_top stat section not found" }
"---- memory-ish cells ----"
Select-String $Log -Pattern 'altsyncram|\$mem|RAMB|BRAM|memory_bram|Mapping' | Select-Object -First 25 | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }
