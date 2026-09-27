param([Parameter(Mandatory=$true)][string]$Log)
Set-Location C:\Workspace\diansai
"==== memory_bram mapping decisions ===="
Select-String $Log -Pattern 'Mapping to bram type|Only the following options|Failed to map|no valid mapping|Assigning bram cell|Storing for later|Using non-conflicting|Creating $__|Note: Replacing memory' |
  ForEach-Object { $_.Line.Trim() } | Group-Object | Sort-Object Count -Descending |
  Select-Object -First 30 | ForEach-Object { "{0,6}  {1}" -f $_.Count, $_.Name }
"==== per-memory summary lines ===="
Select-String $Log -Pattern 'Processing .*\\\$mem|Checking rule|Mapping memory' | Select-Object -First 40 |
  ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }
