"""Independent address/data oracle for the T70 PMEM byte windows.

This checks the expected physical byte stream and split-window coverage only;
it is not a simulation result and does not execute RTL.
"""

CASES = [
    (2047, 1, 2046, [3]),
    (2048, 2047, 1, [4]),
    (2049, 2046, 3, [5, 1]),
    (8191, 8179, 12, [0, 2, 4, 5]),
    (8192, 2047, 4099, [0, 5, 3, 1]),
]


def value(block: int, offset: int) -> int:
    return ((block * 2048 + offset) * 13 + 7) & 0xFF


for app_len, start, count, blocks in CASES:
    assert 0 <= start < app_len
    assert start + count <= app_len
    for pos in range(start, start + count):
        block, in_block = divmod(pos, 2048)
        word, lane = divmod(in_block, 4)
        requested_word_addr = blocks[block] * 512 + word
        returned_lane_addr = requested_word_addr * 4 + lane
        expected_addr = blocks[block] * 2048 + in_block
        assert returned_lane_addr == expected_addr
        assert value(0, returned_lane_addr) == value(blocks[block], in_block)
    print(f"oracle case app_len={app_len} window=[{start},{start + count}) bytes={count}")

print("ORACLE OK (expected stream arithmetic only; RTL not run)")
