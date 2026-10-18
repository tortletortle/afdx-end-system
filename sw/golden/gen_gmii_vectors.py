#!/usr/bin/env python3
"""Independent PHY GMII stimuli for T41/T42. No RTL-derived constants.

The established frame model generates Ethernet/IP/UDP; zlib independently
checks FCS. Preamble/SFD are PHY fields and are excluded from frame lengths.
"""
import json
from pathlib import Path
import zlib
from afdx_model import build_frame, parse_frame

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'sim' / 'vec'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    words = [4]
    records = []
    for length in (1, 32, 1024, 1471):
        payload = bytes((i * 13 + 0x53) & 255 for i in range(length))
        frame, _ = build_frame(0x0100, 0x1234, 1, 1,
                               '10.0.0.1', '224.0.0.1', 49152, 5000,
                               payload, 1, ident=0)
        assert zlib.crc32(frame[:-4]) == int.from_bytes(frame[-4:], 'little')
        parsed = parse_frame(frame)
        assert parsed['payload'] == payload
        assert parsed['fcs_ok'] and parsed['udp_csum_ok']
        base = len(words)
        words.extend((length, len(frame)))
        words.extend(int.from_bytes(frame[i:i+4].ljust(4, b'\0'), 'big')
                     for i in range(0, len(frame), 4))
        records.append({'payload_bytes': length, 'mac_frame_bytes': len(frame),
                        'record_word': base})
    (OUT / 'gmii_frames.hex').write_text(''.join(f'{w:08x}\n' for w in words), encoding='ascii')
    (OUT / 'gmii_vectors.vh').write_text(
        f'`define GMII_VECTOR_WORDS {len(words)}\n', encoding='ascii')
    (OUT / 'gmii_vectors.json').write_text(json.dumps(
        {'schema': 'phy-gmii-v1', 'word_count': len(words), 'cases': records}, indent=2) + '\n', encoding='utf-8')
    print(f'GMII vectors: {len(records)} lengths, {len(words)} words; independent CRC and UDP checks complete')


if __name__ == '__main__':
    main()
