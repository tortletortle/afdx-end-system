# Commands executed

Commands were executed serially. The completed 56-test regression was not rerun, and no second `quartus_map` was started while the existing retry was active.

```powershell
# Verify production QSF assignments
Select-String -Path elinx\prj\quartus\AFDX_top.qsf -Pattern 'FAMILY|DEVICE'

# Retry performed after correcting/reusing production QSF
Set-Location elinx\prj\quartus
& 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_map.exe' AFDX_top

# Primary post-map STA and 8 ns guard
$env:DIANSAI_STA_OUT='C:/Workspace/diansai/out/arena-debug/continue7/step1_sta'
& 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_sta.exe' -t sta_post_map.tcl

# TNS and unconstrained-path summary
& 'C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_sta.exe' -t C:\Workspace\diansai\out\arena-debug\continue7\tns_step1.tcl

# Reverse the timing_step1.patch changes in rtl/tx/tx_port_buf.v,
# then verify against the saved pre-step backup
Get-FileHash -Algorithm SHA256 rtl\tx\tx_port_buf.v
Get-FileHash -Algorithm SHA256 out\arena-debug\continue7\backup\step1\tx_port_buf.v

# Package integrity manifest
Get-FileHash -Algorithm SHA256 <artifact>
```

Execution order: inspect existing evidence → verify QSF/device → wait for the already-running map retry → inspect successful map → run primary STA/SDC guard → run TNS summary → compare with continue6 → reverse Step 1 patch → verify rollback hash → package artifacts.

