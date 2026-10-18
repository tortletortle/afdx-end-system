"""Strict audit of explicit initialization source, not a full 615A workflow."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checksum(data):
    data += bytes(len(data) % 2)
    total = sum((data[i] << 8) | data[i+1] for i in range(0, len(data), 2))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return ~total & 65535


def decode(raw):
    assert raw[:8] == b"\x55"*7+b"\xd5", "preamble"
    body = raw[8:-4]
    assert len(body) >= 60 and body[12:14] == b"\x08\x00", "MAC length/type"
    assert int.from_bytes(raw[-4:], "little") == zlib.crc32(body), "FCS"
    ip = body[14:34]
    length = int.from_bytes(ip[2:4], "big")
    assert ip[0] == 0x45 and ip[9] == 17 and checksum(ip) == 0, "IP header"
    assert length >= 28 and len(body) == max(60, 15+length), "IP length"
    assert not any(body[14+length:-1]) and body[-1] != 0, "pad/SN"
    udp = body[34:14+length]
    assert len(udp) >= 8 and int.from_bytes(udp[4:6], "big") == len(udp), "UDP length"
    assert udp[6:8] != b"\x00\x00", "nonzero checksum"
    assert checksum(ip[12:20]+b"\x00\x11"+udp[4:6]+udp) == 0, "UDP checksum"
    return body, ip, udp


def verify_capture(frames, net):
    assert len(frames) == 4, "frame count"
    payloads = [b"\x00\x02TARGET.LUI\0octet\0",
                bytes.fromhex("00030001000000094131000200"),
                b"\x00\x02TARGET.LUI\0octet\0",
                bytes.fromhex("00030001000000091122334400")]
    for i, raw in enumerate(frames):
        body, ip, udp = decode(raw)
        assert body[:6] == bytes.fromhex("030000000100"), "VL"
        assert body[6:12] == bytes.fromhex("020000172d20" if net==0 else "020000172d40"), "SMAC"
        assert ip[1] == 0 and ip[8] == 255 and ip[6:8] == b"\x00\x00", "IP fields"
        assert ip[12:20] == bytes.fromhex("0a0000020a000001"), "peer IP"
        # TX4 message IDs begin at zero after reset; the per-VL SN begins at one.
        assert int.from_bytes(ip[4:6], "big") == i and body[-1] == i+1, "ID/SN sequence"
        assert struct.unpack("!HH", udp[:4]) == (0x3001,69 if i%2==0 else 40100), "TID"
        assert udp[8:] == payloads[i], "explicit initialization bytes/name/mode"


def rejected(name, action):
    try:
        action()
    except (AssertionError, ValueError, IndexError):
        return name
    raise AssertionError("Known-bad accepted: "+name)


def audit(run):
    target=run/"INIT_SOURCE_AUDIT.json"
    assert not target.exists(), "Refusing to overwrite audit"
    m=json.loads((run/"run_metadata.json").read_text(encoding="utf-8-sig"))
    assert m["regression_result"] == m["compile_result"] == "PASS"
    assert m["return_code"] == m["compile_rc"] == 0
    for rel,digest in m["source_sha256"].items():
        assert sha(run/"workspace"/rel)==digest, rel
    rows=m["test_results"]
    assert len({r['id'] for r in rows}) == len(rows) == len(m['tests'])
    assert {r['id'] for r in rows} == {r['id'] for r in m['tests']}
    sources=(run/'workspace/elinx/AFDX_top_sources.f').read_text(encoding='utf-8').splitlines()
    assert len(sources)==len(set(sources))==50 and 'rtl/mgmt/a615a_init_tx.v' in sources
    assert any(r["id"]=="T84" for r in rows)
    hashes={"run_metadata.json":sha(run/"run_metadata.json")}
    for name in ["compile_console.txt"]+[r["console_log"] for r in rows]:
        text=(run/name).read_text(encoding="utf-8")
        assert "Errors: 0, Warnings: 0" in text, name
        assert not re.search(r"\*\* (?:Error|Fatal|Warning)|\bFAIL\b|\[err\]", text), name
        hashes[name]=sha(run/name)
    assert all(r["result"]=="PASS" and r["simulator_exit_code"]==0 for r in rows)
    log=(run/"T84_console.txt").read_text(encoding="utf-8")
    assert "Loading work.afdx_bind_full" in log
    result=re.findall(r"T84 INIT SOURCE PASS checks=(\d+) jobs=2 frames_per_net=4 file_bytes=18 control_cases=5",log)
    assert len(result)==1 and int(result[0])>=100, "complete verdict"
    for label in ("abort-partial","disable-partial","host-preload-owner","explicit-A1-upload",
                  "raw-tag-restart","published-idle-abort","reset-partial"):
        assert log.count("T84 CASE "+label)==1, label
    streams=[]
    for net,letter in enumerate("ab"):
        path=run/"metrics"/f"t84_init_{letter}.hex"
        frames=[bytes.fromhex(row) for row in path.read_text(encoding="ascii").splitlines()]
        verify_capture(frames,net);streams.append(frames);hashes[path.name]=sha(path)
    assert all(a[8:19]+a[20:-4]==b[8:19]+b[20:-4] for a,b in zip(*streams)), "A/B content"
    golden=run/"workspace/sim/vec/t84_init_source/acks.hex"
    vals=iter(int(w,16) for w in golden.read_text(encoding="ascii").split())
    assert next(vals)==4
    for i in range(4):
        raw=bytes(next(vals) for _ in range(next(vals)))
        body,ip,udp=decode(raw)
        assert ip[12:20]==bytes.fromhex("0a0000010a000002")
        assert struct.unpack("!HH",udp[:4])==(40100,0x3001)
        assert udp[8:]==struct.pack("!HH",4,i%2) and body[-1]==i+1
    assert next(vals,None) is None
    hashes["ACK_vectors"]=sha(golden)
    good=streams[0]
    bad=bytearray(good[1]);bad[58]^=1
    bad[-4:]=struct.pack("<I",zlib.crc32(bad[8:-4]))
    controls=[rejected("file_corruption_valid_FCS",lambda:verify_capture([good[0],bytes(bad)]+good[2:],0)),
              rejected("missing_frame",lambda:verify_capture(good[:-1],0)),
              rejected("reordered_jobs",lambda:verify_capture(good[2:]+good[:2],0)),
              rejected("truncated_frame",lambda:verify_capture([good[0][:-1]]+good[1:],0))]
    report={"status":"PASS","scope":"Explicit fixed9B source to shared preload plus two host-started WRQ jobs; not standard passive LUI RRQ or full615A",
            "frozen_inputs":len(m["source_sha256"]),"production_sources":len(sources),"regression_tests":len(rows),"checks":int(result[0]),
            "frames_per_net":4,"initialization_bytes_per_net":18,"control_cases":5,
            "source_sha256":sha(Path(__file__)),"output_sha256":hashes,"negative_controls_rejected":controls}
    target.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print("INIT SOURCE AUDIT PASS frames_per_net=4 explicit_bytes=18 controls=5 negative_controls=4")


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--run",type=Path,required=True)
    a=p.parse_args();audit(a.run.resolve())
