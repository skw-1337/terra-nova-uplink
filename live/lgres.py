# Reader for Looking Glass "LG Res File v2" archives (as scripts/lgres.gd): {id: (type, flags, data)}; compound
# resources (flag 2) split by frames(), string tables by strings(). LZW-packed resources (flag 1) are not unpacked.
import struct


def load(path):
    d = open(path, 'rb').read()
    if d[:14] != b'LG Res File v2':
        return {}
    diro = struct.unpack_from('<I', d, 0x7C)[0]
    n, off = struct.unpack_from('<HI', d, diro)
    out, p = {}, diro + 6
    for _ in range(n):
        rid, a, b = struct.unpack_from('<HII', d, p)
        p += 10
        size, flags = a & 0xFFFFFF, a >> 24
        length = (b & 0xFFFFFF) if flags & 1 else size
        out[rid] = (b >> 24, flags, d[off:off + length])
        off += (length + 3) & ~3
    return out


def frames(d):
    n = struct.unpack_from('<H', d, 0)[0] if len(d) >= 2 else 0
    o = struct.unpack_from('<%dI' % (n + 1), d, 2) if n else ()
    return [d[o[k]:o[k + 1]] for k in range(n)]


def strings(d):
    return [f.split(b'\0')[0].decode('cp850', 'replace') for f in frames(d)]
