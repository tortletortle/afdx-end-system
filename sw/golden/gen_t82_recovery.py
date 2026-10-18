"""Independent PHY oracle for deliberate TX metadata faults and queued recovery."""
import argparse
import json
from pathlib import Path
import struct
import zlib


def checksum(data):
    data += bytes(len(data) % 2)
    value = sum(struct.unpack('!' + str(len(data)//2) + 'H', data))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return ~value & 65535


def fragment(app, ident, sn, offset):
    src, dst = bytes.fromhex('c0a80101'), bytes.fromhex('c0a80102')
    udp = struct.pack('!HHHH', 0x1234, 0x5678, len(app)+8, 0)
    pseudo = src+dst+struct.pack('!BBH', 0, 17, len(app)+8)
    udp = udp[:6]+struct.pack('!H', checksum(pseudo+udp+app) or 65535)
    payload = udp+app
    more = len(payload)-offset > 1479
    n = 1472 if more else len(payload)-offset
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 12, 20+n, ident,
                     (0x2000 if more else 0)|(offset//8), 255, 17, 0, src, dst)
    ip = ip[:10]+struct.pack('!H', checksum(ip))+ip[12:]
    body = bytes.fromhex('0300000001000200001234200800')+ip+payload[offset:offset+n]
    body += bytes(max(0, 59-len(body)))+bytes([sn])
    other = body[:11]+bytes([0x40])+body[12:]
    def phy(b):
        return bytes.fromhex('55555555555555d5')+b+struct.pack('<I', zlib.crc32(b))
    return phy(body), phy(other)


def generate(out, verify_existing=False):
    words, records, ident, sn = [4], [], 18, 51
    for case, (length, offset, fault) in enumerate(((8192,0,0),(8192,1472,1),(2048,1472,1),(32,0,0))):
        apps = [bytes((case*43+message*17+j*29+9)&255 for j in range(n))
                for message,n in enumerate((length,32,33))]
        expected = []
        if offset:
            expected.append(fragment(apps[0],ident,sn,0)); sn += 1
        for m,app in enumerate(apps[1:],1):
            expected.append(fragment(app,ident+m,sn,0)); sn += 1
        words += [length,offset,fault,len(expected)]+list(apps[0])
        for app in apps[1:]:
            words += [len(app)]+list(app)
        for a,b in expected:
            words += [len(a)]+list(a)+list(b)
        records.append({'case':case, 'failed_length':length, 'failed_offset':offset,
                        'fault':'header_length_zero' if fault==0 else 'reader_block_count_zero',
                        'failed_ident':ident, 'frames_per_net':len(expected),
                        'published_application_bytes':65+(1464 if offset else 0),
                        'successors':[32,33]})
        ident += 3
    outputs = {'cases.hex': '\n'.join(f'{v:08x}' for v in words)+'\n',
               'manifest.json': json.dumps({'cases':records,'frames_per_net':10,
                                            'application_bytes':3188},indent=2)+'\n'}
    if out.exists():
        assert verify_existing, 'Use a new vector directory'
        for name, text in outputs.items():
            assert (out/name).read_text(encoding='utf-8') == text, name
    else:
        out.mkdir(parents=True)
        for name, text in outputs.items():
            (out/name).write_bytes(text.encode('utf-8'))
    print('T82 RECOVERY GOLDEN PASS cases=4 frames_per_net=10 bytes=3188')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--verify-existing',action='store_true')
    args=parser.parse_args()
    generate(args.out,args.verify_existing)
