"""One-top TX4/RX5, redundant RX, host and TFTP coexistence oracle."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib
from gen_rx8k_gmii import Frames, udp, payload, hash_bucket, verify_datagram


def checksum(data):
    data += bytes(len(data) % 2)
    n=sum(struct.unpack('!'+str(len(data)//2)+'H',data))
    while n>>16:n=(n&65535)+(n>>16)
    return ~n&65535


def outgoing(app, vl, ident, sn, offset=0, management=False):
    src=bytes.fromhex('0a000002');dst=bytes.fromhex('0a000001' if management else 'c0a80102')
    sport,dport=(5000,49152) if management else (0x1234,0x5678)
    u=struct.pack('!HHHH',sport,dport,len(app)+8,0)
    pseudo=src+dst+struct.pack('!BBH',0,17,len(app)+8)
    u=u[:6]+struct.pack('!H',checksum(pseudo+u+app) or 65535)
    data=u+app;more=len(data)-offset>1479;n=1472 if more else len(data)-offset
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0 if management else 12,20+n,ident,
                   (0x2000 if more else 0)|offset//8,255,17,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    a=bytes.fromhex('03000000')+vl.to_bytes(2,'big')+bytes.fromhex('020000172d200800')+ip+data[offset:offset+n]
    a+=bytes(max(0,59-len(a)))+bytes([sn])
    b=a[:11]+bytes([0x40])+a[12:]
    def phy(body):return bytes.fromhex('55555555555555d5')+body+struct.pack('<I',zlib.crc32(body))
    return phy(a),phy(b)


def request(app,sn,ident):
    src,dst=bytes.fromhex('0a000001'),bytes.fromhex('e0000001')
    u=struct.pack('!HHHH',49152,5000,len(app)+8,0)
    u=u[:6]+struct.pack('!H',checksum(src+dst+struct.pack('!BBH',0,17,len(app)+8)+u+app) or 65535)
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(u)+len(app),ident,0x4000,1,17,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    body=bytes.fromhex('0300000001000200001234200800')+ip+u+app
    body+=bytes(max(0,59-len(body)))+bytes([sn])
    return bytes.fromhex('55555555555555d5')+body+struct.pack('<I',zlib.crc32(body))


def generate(out,verify=False):
    # Cases use a fresh public reset/configuration so both golden SN/ID streams
    # are fully deterministic. The invalid/incomplete datagrams are explicit.
    words=[3];records=[]
    file_app=bytes((j*11+7)&255 for j in range(520))
    for case in range(3):
        tx_app=bytes((j*37+case*19+3)&255 for j in range(8192))
        rx_app=payload(8192,100+case);held=payload(64,200+case)
        f=Frames();held_frames=f.pieces(udp(held,5001),0x7000,vl=6)
        dg=bytearray(udp(rx_app))
        if case==1:dg[6]^=1
        prefix=f.pieces(bytes(dg),0x7100,order='tail_first')
        if case==2:prefix=prefix[:5];f.sn[5]=5
        recovery=f.pieces(udp(rx_app),0x7200,order='shuffled') if case else []
        if case:verify_datagram(recovery,rx_app)
        else:verify_datagram(prefix,rx_app)
        rx_frames=held_frames+prefix+recovery
        words += [case,len(rx_frames),len(prefix),len(recovery)]+list(tx_app)+list(rx_app)+list(held)
        for raw in rx_frames:
            a=bytes.fromhex('55555555555555d5')+raw
            bbody=raw[:-4];bbody=bbody[:11]+bytes([0x40])+bbody[12:]
            b=bytes.fromhex('55555555555555d5')+bbody+struct.pack('<I',zlib.crc32(bbody))
            words += [len(a)]+list(a)+list(b)
        off=0
        for sn in range(1,7):
            a,b=outgoing(tx_app,0x100,0,sn,off)
            words += [len(a)]+list(a)+list(b);off+=1472 if sn<6 else 840
        management=[b'\x00\x02UPLOAD\0octet\0',b'\x00\x03\x00\x01'+file_app[:512],b'\x00\x03\x00\x02'+file_app[512:]]
        for sn,app in enumerate(management,1):
            raw=request(app,sn,0x7300+sn)
            a,b=outgoing(struct.pack('!HH',4,sn-1),0x101,sn,sn,management=True)
            words += [len(raw)]+list(raw)+[len(a)]+list(a)+list(b)
        records.append({'case':case,'kind':['simultaneous_success','bad_udp_then_recovery','disable_incomplete_then_recovery'][case],
                        'tx_app_bytes':8192,'rx_app_bytes':8192,'held_app_bytes':64,
                        'rx_frames_per_net':len(rx_frames),'prefix_frames':len(prefix),'recovery_frames':len(recovery),
                        'tx_data_frames_per_net':6,'management_frames_per_net':3,
                        'tftp_file_bytes':520,'tx_app_sha256':hashlib.sha256(tx_app).hexdigest(),
                        'rx_app_sha256':hashlib.sha256(rx_app).hexdigest()})
    image=[0]*8192
    for vl,index in ((5,5),(6,6),(0x100,0x100)):
        slot=2*hash_bucket(vl,0x172d,0)
        assert not image[slot]
        image[slot]=(1<<28)|(index<<12)|vl
    files={'cases.hex':'\n'.join(f'{v:08x}' for v in words)+'\n',
           'hash_img.hex':'\n'.join(f'{v:08x}' for v in image)+'\n',
           'manifest.json':json.dumps({'cases':records,'words':len(words)},indent=2)+'\n'}
    if out.exists():
        assert verify,'Refusing to overwrite vectors'
        for name,content in files.items():assert (out/name).read_text(encoding='utf-8')==content,name
    else:
        out.mkdir(parents=True)
        for name,content in files.items():(out/name).write_bytes(content.encode('utf-8'))
    print(f'T83 COEXIST GOLDEN PASS cases=3 words={len(words)}; HDL NOT_RUN')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--verify-existing',action='store_true');args=p.parse_args()
    generate(args.out,args.verify_existing)
