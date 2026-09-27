from execute import *
exe='C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe'
for name,script in [('old_top_repro',D/'old_top_repro.ys'),('current_top_repro',P/'elinx/prj/AFDX_top_synth.ys'),('rx_cfg_isolate',D/'rx_cfg_isolate.ys'),('top_fast_probe',D/'top_fast_probe.ys')]:
 run(name,[exe,'-s',str(script),'-l',str(D/(name+'_tool.log'))],timeout=300)
run('sta_probe',['C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sta.exe','-t',str(P/'out/arena-debug/finalize/sta/sta_probe.tcl')])
