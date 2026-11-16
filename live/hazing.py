# The game's haze table (0x2B4E8C, "hazeRadius"): 1024 bytes, the haze level 0..15 of each distance ring,
# level(d) = 0 up to 20, then min(15, floor(16 (1 - exp(-(d - 20) / k)))), k = the mission's haze radius (res 178
# +0x10 x 25558 >> 16: 99 in most missions). Terra Nova Plus rewrites it from outside (its FAR distance: k = 180), so
# the live view reads the table itself and finds its k.
import math, re, struct

# the ring lookup (0x2B580A): mov ebx, [ebp-0xC]; xor eax, eax; mov al, [ebx + table]
SIG_TABLE = re.compile(re.escape(bytes.fromhex('8b5df431c08a83')) + b'(....)', re.S)


def table_address(code, base):
    """the table's address from the game's code (code = bytes read at linear address base), or None"""
    m = SIG_TABLE.search(code)
    if not m:
        return None
    a = struct.unpack('<I', m.group(1))[0]
    return a if 0x300000 <= a < 0x500000 else None


def level(d, k):
    if d <= 20:
        return 0
    return min(15, int(16 * (1 - math.exp(-(d - 20) / k))))


_cache = {}


def radius(table):
    """the k whose table matches best (exact for the game's own and TN+'s), or None for a table that is no haze"""
    t = bytes(table[:1024])
    if len(t) < 1024 or max(t) > 15:
        return None
    if t in _cache:
        return _cache[t]
    starts = [next((d for d in range(1024) if t[d] >= lv), 1024) for lv in range(1, 16)]
    best, best_err = None, None
    for k in range(1, 1000):
        err = sum(abs(next((d for d in range(1024) if level(d, k) >= lv), 1024) - s) for lv, s in zip(range(1, 16), starts))
        if best_err is None or err < best_err:
            best, best_err = k, err
            if err == 0:
                break
    _cache[t] = best
    return best
