"""Extract files from the rcc bundle whose names table was found by rcc_probe."""
import struct, sys, zlib

try:
    import zstandard as zstd
except ImportError:
    zstd = None

data = open(sys.argv[1], 'rb').read()
NAMES = 0x10A5090
NAMES_END = 0x10A517A
name_offs = {0x0: 'qt', 0xA: 'qml', 0x16: 'xofm', 0x24: 'modules',
             0x38: 'sleepscreen', 0x54: 'qmldir', 0x66: 'SleepWindowBannerWindow.qml',
             0xA2: 'default', 0xB6: 'sleep-window-opaque.qml'}

ENTRY = 22  # rcc v2/v3


def try_tree(t):
    """Parse tree at t; root must be name_off=0, flags=2(dir)."""
    name_off, flags = struct.unpack_from('>IH', data, t)
    if name_off != 0 or flags != 2:
        return None
    count, first = struct.unpack_from('>II', data, t + 6)
    if not (1 <= count <= 5 and 1 <= first <= 20):
        return None
    entries = []
    for i in range(16):  # bundle is tiny; read up to 16 entries
        off = t + i * ENTRY
        n_off, fl = struct.unpack_from('>IH', data, off)
        if n_off not in name_offs and not (i == 0 and n_off == 0):
            break
        if fl & 2:
            cnt, fst = struct.unpack_from('>II', data, off + 6)
            entries.append((i, name_offs.get(n_off, '?'), 'dir', cnt, fst))
        else:
            locale, d_off = struct.unpack_from('>II', data, off + 6)
            entries.append((i, name_offs.get(n_off, '?'), 'file', fl, d_off))
    return entries if len(entries) >= 6 else None


tree_at, tree = None, None
for t in range(NAMES - 0x2000, NAMES + 0x2000, 2):
    r = try_tree(t)
    if r:
        tree_at, tree = t, r
        break
if not tree:
    sys.exit('tree not found')
print(f'tree at 0x{tree_at:x}:')
for e in tree:
    print('  ', e)

# find data table: file entries carry data_off relative to data start.
file_entries = [e for e in tree if e[2] == 'file']
d_offs = sorted(e[4] for e in file_entries)


def valid_data(ds):
    for do in d_offs:
        p = ds + do
        if p + 4 > len(data):
            return False
        ln = struct.unpack_from('>I', data, p)[0]
        if ln == 0 or ln > 5_000_000 or p + 4 + ln > len(data):
            return False
    return True


data_at = None
for ds in range(max(0, tree_at - 0x400000), tree_at + 0x10000, 2):
    if valid_data(ds):
        # extra check: at least one blob starts with zstd/zlib magic or ascii
        ok = False
        for do in d_offs:
            payload = data[ds + do + 4: ds + do + 8]
            if payload[:4] == b'\x28\xb5\x2f\xfd' or payload[:1] == b'\x78':
                ok = True
        if ok:
            data_at = ds
            break
if data_at is None:
    sys.exit('data table not found')
print(f'data table at 0x{data_at:x}')

for e in file_entries:
    _, name, _, flags, d_off = e
    p = data_at + d_off
    ln = struct.unpack_from('>I', data, p)[0]
    blob = data[p + 4: p + 4 + ln]
    if flags & 4:  # zstd
        if zstd is None:
            print(f'{name}: zstd ({ln}B) - install zstandard')
            continue
        out = zstd.ZstdDecompressor().decompress(blob)
    elif flags & 1:  # zlib, first 4 bytes = uncompressed size
        out = zlib.decompress(blob[4:])
    else:
        out = blob
    fn = f'research/extracted_{name.replace("/", "_")}'
    open(fn, 'wb').write(out)
    print(f'{name}: flags={flags} {ln}B -> {fn} ({len(out)}B)')
