"""Locate the rcc bundle around a known UTF-16BE name entry and map its tables.

Name entry: [u16 len BE][u32 hash BE][utf16be chars]
Tree entry v2/v3 (22B): [u32 name_off][u16 flags][payload 8B][u64 mtime]
  dir:  payload = child_count(4) + first_child(4)
  file: payload = country(2)+lang(2) style locale(4) + data_off(4)... actually
        locale(4) + data_off(4); flags: 1=zlib, 2=dir, 4=zstd
Data entry: [u32 len BE][payload]
"""
import struct, sys

data = open(sys.argv[1], 'rb').read()
ANCHOR = 0x10A5146  # entry start of 'sleep-window-opaque.qml'


def parse_names(start, limit):
    """Forward-parse name entries; return list of (entry_off, name) or None."""
    out, p = [], start
    while p < limit:
        if p + 6 > len(data):
            return None
        ln = struct.unpack_from('>H', data, p)[0]
        if ln == 0 or ln > 200:
            return None
        end = p + 6 + ln * 2
        if end > len(data):
            return None
        try:
            name = data[p + 6:end].decode('utf-16-be')
        except UnicodeDecodeError:
            return None
        if not all(32 <= ord(c) < 0x3000 for c in name):
            return None
        out.append((p, name))
        p = end
    return out if p == limit else out


# 1. find names-table start: farthest-back start that forward-parses through ANCHOR
best = None
for back in range(0, 0x20000, 2):
    s = ANCHOR - back
    if s < 0:
        break
    res = parse_names(s, ANCHOR + 6)
    if res and any(off == ANCHOR for off, _ in res):
        best = s
if best is None:
    sys.exit('no names start found')

# extend forward to find table end
names = []
p = best
while True:
    res = parse_names(p, p + 6)
    if not res:
        break
    ln = struct.unpack_from('>H', data, p)[0]
    entry_end = p + 6 + ln * 2
    one = parse_names(p, entry_end)
    if not one:
        break
    names.append((p - best, one[0][1]))
    p = entry_end
print(f'names table: 0x{best:x} - 0x{p:x}, {len(names)} entries')
for off, n in names:
    print(f'  +0x{off:04x} {n}')
