from execute import *
for n in ['tx_rm_old','tx_rm_current']:
 run(n,['C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe','-s',str(D/(n+'.ys')),'-l',str(D/(n+'_tool.log'))])
