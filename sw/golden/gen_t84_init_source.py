"""Frozen ACK inputs for explicit initialization-source WRQ integration."""
import argparse
from pathlib import Path
import struct
from afdx_model import build_frame, parse_frame

def generate(out, verify=False):
    words=[4]
    for n in range(4):
        body,_=build_frame(0x100,0x172D,1,1,"10.0.0.1","10.0.0.2",40100,0x3001,
                           struct.pack("!HH",4,n%2),n+1,ident=0,tos=0,ttl=255)
        parsed=parse_frame(body)
        assert parsed["fcs_ok"] and parsed["udp_csum_ok"]
        raw=bytes.fromhex("55555555555555d5")+body
        words += [len(raw)]+list(raw)
    text="".join(f"{w:08x}\n" for w in words)
    target=out/"acks.hex"
    if verify:
        assert target.read_text(encoding="ascii")==text, "Frozen ACK vector differs"
    else:
        assert not target.exists(), "Refusing to overwrite vectors"
        out.mkdir(parents=True,exist_ok=True)
        target.write_text(text,encoding="ascii")
    print("T84 INIT ACK GOLDEN PASS frames=4 words="+str(len(words)))

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--out",type=Path,required=True)
    p.add_argument("--verify-existing",action="store_true")
    a=p.parse_args();generate(a.out,a.verify_existing)
