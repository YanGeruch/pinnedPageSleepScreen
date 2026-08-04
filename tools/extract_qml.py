"""Extract any QML file from xochitl's embedded rcc bundles by file name.

Bundle layout observed: [data table][names table][tree table].
Usage: extract_qml.py <xochitl> <outdir> <resource-path> [...]
  resource-path like /qml/device/view/documentview/PagesActions.qml
"""
import struct, sys, zlib
import zstandard

data = open(sys.argv[1], 'rb').read()
outdir = sys.argv[2]
ENTRY = 22
MAGIC = b'\x28\xb5\x2f\xfd'


def parse_names_forward(start, stop_after=None):
    out, p = [], start
    while True:
        if p + 6 > len(data):
            break
        ln = struct.unpack_from('>H', data, p)[0]
        if ln == 0 or ln > 200:
            break
        end = p + 6 + ln * 2
        try:
            name = data[p + 6:end].decode('utf-16-be')
        except UnicodeDecodeError:
            break
        if not name or not all(31 < ord(c) < 0x3000 for c in name):
            break
        out.append((p, name))
        p = end
        if stop_after is not None and p > stop_after:
            break
    return out, p


def find_bundle(fname):
    """Find (names_start, names_end, name_offsets dict) for bundle containing fname."""
    needle = fname.encode('utf-16-be')
    i = -1
    while True:
        i = data.find(needle, i + 1)
        if i < 0:
            return None
        entry = i - 6
        ln = struct.unpack_from('>H', data, entry)[0]
        if ln != len(fname):
            continue
        # walk back to find table start
        best = entry
        for back in range(2, 0x40000, 2):
            s = entry - back
            if s < 0:
                break
            res, endp = parse_names_forward(s, stop_after=entry)
            if res and any(off == entry for off, _ in res):
                best = s
        names, end = parse_names_forward(best)
        if any(n == fname for _, n in names):
            return best, end, {off - best: n for off, n in names}


def find_tree(names_end, name_offs):
    for t in range(names_end, names_end + 64, 2):
        n_off, flags = struct.unpack_from('>IH', data, t)
        if flags != 2:
            continue
        count, first = struct.unpack_from('>II', data, t + 6)
        if not (1 <= count <= 1000 and 1 <= first <= 5000):
            continue
        # validate a handful of entries
        entries = []
        i = 0
        while True:
            off = t + i * ENTRY
            n_off, fl = struct.unpack_from('>IH', data, off)
            if i > 0 and n_off not in name_offs:
                break
            a, b = struct.unpack_from('>II', data, off + 6)
            entries.append((i, name_offs.get(n_off, '<root>'), fl, a, b))
            i += 1
            if i > 5000:
                break
        if len(entries) >= 3:
            return t, entries
    return None, None


def find_data(names_start, file_entries):
    d_offs = [e[4] for e in file_entries]
    zstd_offs = [e[4] for e in file_entries if e[2] & 4]
    hi = names_start
    for ds in range(hi - 4, max(0, hi - 0x4000000), -2):
        ok = True
        for do in d_offs:
            p = ds + do
            if p + 4 > len(data):
                ok = False; break
            ln = struct.unpack_from('>I', data, p)[0]
            if ln == 0 or ln > 10_000_000 or ds + do + 4 + ln > hi:
                ok = False; break
        if not ok:
            continue
        if all(data[ds + do + 4: ds + do + 8] == MAGIC for do in zstd_offs):
            return ds
    return None


def build_paths(entries):
    """Resolve full path for each file entry via tree structure."""
    # entries: (idx, name, flags, a, b); dirs: a=child_count b=first_child
    paths = {}
    def walk(idx, prefix):
        _, name, fl, a, b = entries[idx]
        cur = prefix if idx == 0 else prefix + '/' + name
        if fl & 2:
            for c in range(b, b + a):
                if c < len(entries):
                    walk(c, cur)
        else:
            paths[cur] = entries[idx]
    walk(0, '')
    return paths


targets = sys.argv[3:]
done = set()
for tgt in targets:
    base = tgt.rsplit('/', 1)[-1]
    found = find_bundle(base)
    if not found:
        print(f'{tgt}: bundle not found'); continue
    ns, ne, name_offs = found
    t, entries = find_tree(ne, name_offs)
    if not entries:
        print(f'{tgt}: tree not found (names at 0x{ns:x})'); continue
    paths_pre = build_paths(entries)
    files = [e for e in paths_pre.values() if not e[2] & 2]
    ds = find_data(ns, files)
    if ds is None:
        print(f'{tgt}: data table not found'); continue
    paths = build_paths(entries)
    match = [p for p in paths if p.endswith(base)]
    for m in match:
        _, name, fl, loc, d_off = paths[m]
        p = ds + d_off
        ln = struct.unpack_from('>I', data, p)[0]
        blob = data[p + 4: p + 4 + ln]
        if fl & 4:
            out = zstandard.ZstdDecompressor().decompress(blob, max_output_size=20_000_000)
        elif fl & 1:
            out = zlib.decompress(blob[4:])
        else:
            out = blob
        import os
        dest = os.path.join(outdir, m.lstrip('/'))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        open(dest, 'wb').write(out)
        print(f'{m} -> {dest} ({len(out)}B)')
        done.add(m)
