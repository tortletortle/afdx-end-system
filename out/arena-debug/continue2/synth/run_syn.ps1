# continue2 顶层综合运行器：固定记录 rc / 耗时 / 首个 ERROR / 最后一个 pass / SHA256。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/synth/run_syn.ps1 -Ys <path> -Name <tag> [-TimeoutS 900]
param([Parameter(Mandatory=$true)][string]$Ys,[Parameter(Mandatory=$true)][string]$Name,[int]$TimeoutS=900)
Set-Location C:\Workspace\diansai
$d='out/arena-debug/continue2/synth'
New-Item -ItemType Directory -Force -Path $d | Out-Null
$exe='C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe'
$t=Get-Date
$p=Start-Process -FilePath $exe -ArgumentList @('-s',$Ys,'-l',"$d/$Name.log") -NoNewWindow -PassThru -RedirectStandardOutput "$d/${Name}_console.log" -RedirectStandardError "$d/${Name}_console.err"
$null=$p.Handle
$ok=$p.WaitForExit($TimeoutS*1000)
if(-not $ok){ $p.Kill(); $p.WaitForExit(); $rc="TIMEOUT_KILLED_${TimeoutS}s" } else { $rc=$p.ExitCode }
$el=[int]((Get-Date)-$t).TotalSeconds
$err=(Select-String "$d/$Name.log" -Pattern '^ERROR' | Select-Object -First 1).Line
$nerr=(Select-String "$d/$Name.log" -Pattern '^ERROR' | Measure-Object).Count
$last=(Select-String "$d/$Name.log" -Pattern 'Executing \S+ pass' | Select-Object -Last 1).Line
$ok2=(Select-String "$d/$Name.log" -Pattern 'Yosys execute success!' | Measure-Object).Count
$h=(Get-FileHash "$d/$Name.log" -Algorithm SHA256).Hash
$line="name=$Name ys=$Ys exit_code=$rc elapsed_s=$el error_lines=$nerr success_banner=$ok2 first_error=$err last_pass=$last log_sha256=$h"
$line | Set-Content -Encoding ascii "$d/${Name}_rc.txt"
$line
