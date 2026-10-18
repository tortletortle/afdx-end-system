"""Golden public-host to PHY-GMII TX complete-message vectors."""
import argparse
import json
from pathlib import Path
import struct
import zlib


def checksum(data):
    data+=bytes(len(data)%2)
    value=sum(struct.unpack('!'+str(len(data)//2)+'H',data))
    while value>>16:value=(value&65535)+(value>>16)
    return ~value&65535


def generate(out, verify_existing=False):
    records=[];cases=[];sn=1
    lengths=(1471,1472,2007,2048,2049,4096,8191,8192,32)
    for message,(length,enabled) in enumerate((n,e) for n in lengths for e in (0,1)):
        app=bytes((message*19+j*37+3)&255 for j in range(length))
        src=bytes.fromhex('c0a80101');dst=bytes.fromhex('c0a80102')
        udp=struct.pack('!HHHH',0x1234,0x5678,length+8,0)
        pseudo=src+dst+struct.pack('!BBH',0,17,length+8)
        udp=udp[:6]+struct.pack('!H',(checksum(pseudo+udp+app) or 65535) if enabled else 0)
        ipdata=udp+app
        assert not enabled or checksum(pseudo+ipdata)==0
        fragments=[];offset=0
        while offset<len(ipdata):
            left=len(ipdata)-offset;more=left>1479;n=1472 if more else left
            ip=struct.pack('!BBHHHBBH4s4s',0x45,12,20+n,message,(0x2000 if more else 0)|(offset//8),255,17,0,src,dst)
            ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:];assert checksum(ip)==0
            eth=bytes.fromhex('0300000001000200001234200800')
            body=eth+ip+ipdata[offset:offset+n]
            body+=bytes(max(0,59-len(body)))+bytes([sn])
            other=body[:11]+bytes([0x40])+body[12:]
            phy=lambda b:bytes.fromhex('55555555555555d5')+b+struct.pack('<I',zlib.crc32(b))
            a,b=phy(body),phy(other)
            fragments.append((a,b));offset+=n;sn=1 if sn==255 else sn+1
        records += [length,enabled,len(fragments)]+list(app)
        for a,b in fragments:records += [len(a)]+list(a)+list(b)
        cases.append(dict(message=message,length=length,checksum=enabled,frames=len(fragments),readback_bytes=length))
    outputs = {
        'cases.hex': '\n'.join(f'{v:08x}' for v in [len(cases)]+records)+'\n',
        'manifest.json': json.dumps({'case_count':len(cases),'cases':cases,'frames_per_net':sum(c['frames'] for c in cases)},indent=2)+'\n',
    }
    if out.exists():
        assert verify_existing, 'Use a new vector directory'
        for name, text in outputs.items():
            # Existing Windows fixtures use CRLF; compare canonical text
            # without rewriting their bytes or changing any encoded value.
            assert (out/name).read_text(encoding='utf-8') == text, name
    else:
        out.mkdir(parents=True)
        for name, text in outputs.items():
            (out/name).write_bytes(text.encode('utf-8'))
    print(f'T82 GOLDEN PASS messages={len(cases)} frames_per_net={sum(c["frames"] for c in cases)}')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--verify-existing',action='store_true')
    args=parser.parse_args()
    generate(args.out,args.verify_existing)
