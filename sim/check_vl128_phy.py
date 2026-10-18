"""Independent complete-frame and timing audit of all128 active TX VLs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib


def checksum(data):
    data += bytes(len(data)%2)
    total=sum((data[i]<<8)+data[i+1] for i in range(0,len(data),2))
    while total>>16:total=(total&65535)+(total>>16)
    return ~total&65535


def expected(vl,sequence,net):
    app=b''.join(bytes((0xA5,vl,0,k)) for k in range(4))
    src,dst=bytes.fromhex('0a000001'),bytes.fromhex('e0000001')
    udp=struct.pack('!HHHH',5000+vl,49152+vl,24,0)
    udp=udp[:6]+struct.pack('!H',checksum(src+dst+b'\x00\x11\x00\x18'+udp+app))
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,44,0,0x4000,255,17,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    body=b'\x03\x00\x00\x00'+(0x100+vl).to_bytes(2,'big')+bytes.fromhex('0200001234')+bytes((0x20 if net==0 else 0x40,))+b'\x08\x00'+ip+udp+app+b'\x00'+bytes((sequence,))
    return b'\x55'*7+b'\xd5'+body+struct.pack('<I',zlib.crc32(body))


def verify(frames,cycles,rounds,net,reference):
    assert len(frames)==len(cycles)==128*rounds,'full frame count'
    counts=[0]*128;previous=[None]*128;last_end=None
    max_phase=0;gaps=[];min_ifg=10**9
    for raw,ends in zip(frames,cycles):
        assert len(raw)==72 and len(ends)==2,'frame/timing lengths'
        vl=int.from_bytes(raw[12:14],'big')-0x100
        assert 0<=vl<128,'active VL range'
        sequence=counts[vl]%255+1
        assert raw==expected(vl,sequence,net),'complete independent PHY bytes/payload/SN/order'
        start,end=ends
        assert end-start+1==72,'contiguous PHY bytes'
        if last_end is not None:
            ifg=start-last_end-1;assert ifg>=12,'IFG';min_ifg=min(min_ifg,ifg)
        if previous[vl] is not None:
            interval=start-previous[vl];assert 125000<=interval<=131250,'legal1ms BAG+50us deviation'
            gaps.append(interval)
        nominal=reference+vl*125000//128+counts[vl]*125000
        phase=abs(start-nominal);assert phase<=6250,'phase drift50us'
        if counts[vl]==0:assert start>=nominal,'first departure before phase'
        max_phase=max(max_phase,phase);counts[vl]+=1;previous[vl]=start;last_end=end
    assert counts==[rounds]*128,'actual perVL coverage'
    assert len(gaps)==128*(rounds-1),'all steady intervals'
    window_ns=(cycles[-1][1]-cycles[0][0]+1)*8
    return {'active_vls':128,'rounds_per_vl':rounds,'frames':len(frames),'application_bytes':len(frames)*16,
            'window_ns':window_ns,'useful_payload_mbps':len(frames)*16*8000/window_ns,
            'steady_intervals':len(gaps),'bag_gap_min_cycles':min(gaps),'bag_gap_max_cycles':max(gaps),
            'max_phase_drift_ns':max_phase*8,'minimum_ifg_cycles':min_ifg}


def reject(name,action):
    try:action()
    except (AssertionError,ValueError,IndexError):return name
    raise AssertionError('Known-bad accepted: '+name)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('console',type=Path);p.add_argument('--capture-a',type=Path,required=True)
    p.add_argument('--capture-b',type=Path,required=True);p.add_argument('--cycles-a',type=Path,required=True)
    p.add_argument('--cycles-b',type=Path,required=True);p.add_argument('--rounds',type=int,required=True)
    p.add_argument('--test-id',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();assert a.rounds in (16,100) and a.test_id in ('T33','T34')
    assert not a.out.exists(),'Refusing to overwrite audit'
    log=a.console.read_text(encoding='utf-8')
    assert 'Errors: 0, Warnings: 0' in log
    assert not re.search(r'\*\* (?:Error|Fatal|Warning)|\bFAIL\b|\[err\]|\[chk\]',log),'strict raw log'
    verdict=re.findall(a.test_id+r' VL128 PASS \(IF_MODE=2 BAG=1ms N=128 rounds=(\d+) via net_model\)',log)
    assert verdict==[str(a.rounds)],'unique complete verdict'
    ref=re.findall(a.test_id+r'_PHY_REFERENCE cycle=(\d+)',log);assert len(ref)==1
    reference=int(ref[0]);hashes={};records=[];streams=[];timings=[]
    for net,(capture,timing) in enumerate(((a.capture_a,a.cycles_a),(a.capture_b,a.cycles_b))):
        frames=[bytes.fromhex(row) for row in capture.read_text(encoding='ascii').splitlines()]
        cycles=[tuple(map(int,row.split())) for row in timing.read_text(encoding='ascii').splitlines()]
        records.append(verify(frames,cycles,a.rounds,net,reference));streams.append(frames);timings.append(cycles)
        for path in (capture,timing):hashes[path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
    assert [raw[12:14] for raw in streams[0]]==[raw[12:14] for raw in streams[1]],'A/B VL order'
    good=streams[0];cycles=timings[0]
    corrupted=bytearray(good[0]);corrupted[50]^=1
    corrupted[-4:]=struct.pack('<I',zlib.crc32(corrupted[8:-4]))
    controls=[reject('valid_FCS_payload_corruption',lambda:verify([bytes(corrupted)]+good[1:],cycles,a.rounds,0,reference)),
              reject('missing_frame',lambda:verify(good[:-1],cycles,a.rounds,0,reference)),
              reject('extra_frame',lambda:verify(good+[good[-1]],cycles,a.rounds,0,reference)),
              reject('truncated_frame',lambda:verify([good[0][:-1]]+good[1:],cycles,a.rounds,0,reference))]
    # Preserve every byte and frame count while introducing invalid timing.
    bad=list(cycles);bad[1]=(bad[0][1]+1,bad[0][1]+72)
    controls.append(reject('IFG_violation',lambda:verify(good,bad,a.rounds,0,reference)))
    i=next(i for i in range(1,len(good)) if good[i][12:14]==good[0][12:14])
    bad=list(cycles);bad[i]=(cycles[0][0]+124999,cycles[0][0]+125070)
    controls.append(reject('BAG_violation',lambda:verify(good,bad,a.rounds,0,reference)))
    swapped=list(good);swapped[0],swapped[i]=swapped[i],swapped[0]
    controls.append(reject('perVL_sequence_reorder',lambda:verify(swapped,cycles,a.rounds,0,reference)))
    result={'status':'PASS','scope':'Full128 active VL PHY bytes and timing; small16B scale load is not the100Mbps throughput workload',
            'test':a.test_id+'p','networks':records,'negative_controls_rejected':controls,'output_sha256':hashes,
            'console_sha256':hashlib.sha256(a.console.read_bytes()).hexdigest(),'auditor_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    a.out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(f'VL128_PHY_AUDIT_PASS active_vls=128 rounds={a.rounds} frames_per_net={128*a.rounds} negative_controls={len(controls)}')


if __name__=='__main__':main()
