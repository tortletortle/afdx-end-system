# Commands executed

All commands were run serially from `C:\Workspace\diansai`; no two Questa runs overlapped.

```powershell
powershell -ExecutionPolicy Bypass -File sim\run_regress.ps1
& 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_map.exe' AFDX_top
$env:DIANSAI_STA_OUT='<step output>'; & 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_sta.exe' -t sta_post_map.tcl
& 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_sta.exe' -t out\arena-debug\continue6\tns_step2.tcl
git diff --no-index --binary -- <backup> <current>
Get-FileHash -Algorithm SHA256 <artifact>
```

Execution order: baseline regression → failed baseline map attempt → Step 1 edit → full regression → map → STA → Step 2 edit → full regression → map → STA → TNS summary → packaging.

