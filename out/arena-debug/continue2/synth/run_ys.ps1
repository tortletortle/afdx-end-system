param([string]$Name,[string]$Body,[int]$TimeoutS=420)
Set-Location C:\Workspace\diansai
$d='out/arena-debug/continue2/synth'
$files=(Select-String elinx\prj\AFDX_top_synth.ys -Pattern 'C:/Workspace/diansai/rtl/\S+\.v' -AllMatches | % { $_.Matches.Value }) -join ' '
$ys="read_verilog $files`n$Body`n"
Set-Content -Encoding ascii "$d/$Name.ys" $ys
$exe='C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe'
$t=Get-Date
$p=Start-Process -FilePath $exe -ArgumentList @('-s',"$d/$Name.ys",'-l',"$d/$Name.log") -NoNewWindow -PassThru -RedirectStandardOutput "$d/${Name}_console.log" -RedirectStandardError "$d/${Name}_console.err"
$null=$p.Handle; $ok=$p.WaitForExit($TimeoutS*1000)
if(-not $ok){ $p.Kill(); $rc="TIMEOUT_KILLED_${TimeoutS}s" } else { $rc=$p.ExitCode }
$el=[int]((Get-Date)-$t).TotalSeconds
$err=(Select-String "$d/$Name.log" -Pattern '^ERROR' | select -First 1).Line
$last=(Select-String "$d/$Name.log" -Pattern 'Executing \S+ pass' | select -Last 1).Line
"exit_code=$rc elapsed_s=$el first_error=$err last_pass=$last" | Set-Content "$d/${Name}_rc.txt"
"$Name :: exit_code=$rc elapsed_s=$el err=$err last=$last"


