from execute import *
import struct
files=['C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe','C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sta.exe','C:/altera_pro/26.1.1/questa_fse/win64/vlog.exe','C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe','C:/altera_pro/26.1.1/questa_fse/win64/vcover.exe']
a=[]
for f in files:
 p=pathlib.Path(f);b=p.read_bytes();offset=struct.unpack_from('<I',b,0x3c)[0];machine=struct.unpack_from('<H',b,offset+4)[0]
 a.append(dict(path=f,bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),PE_machine=hex(machine)))
(D/'tool_inventory.json').write_text(json.dumps(a,indent=2));print(json.dumps(a,indent=2))
