# Test of mission_play.py's save without the game: made-up saves in a temporary TNOVA folder.
#   python live/test_mission_play.py
import hashlib
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lgres
import mission_play as MP

fails = 0


def check(ok, what):
    global fails
    fails += 0 if ok else 1
    print(('ok   ' if ok else 'FAIL ') + what)


def save(tnova, slot, name, mission, position):
    head = struct.pack('<6i', MP.MAGIC, mission, position, 8275, 37, 135)
    MP._raw_write(os.path.join(tnova, 'SAVE%02d.RES' % slot), [
        [1775, 0, 0, len(name) + 1, name.encode() + b'\0'],
        [1776, 0, 0, len(head), head],
        [1777, 1, 0, 384, bytes(range(112))],            # a packed resource: kept as stored, with its unpacked size
        [1778, 2, 0, 6, b'\0\0\x06\0\0\0']])


def md5s(tnova):
    return {f: hashlib.md5(open(os.path.join(tnova, f), 'rb').read()).hexdigest() for f in sorted(os.listdir(tnova)) if f.startswith('SAVE')}


with tempfile.TemporaryDirectory() as tmp:
    tnova = os.path.join(tmp, 'TNOVA')
    data = os.path.join(tnova, 'DATA')
    os.makedirs(data)
    for n in (37, 1, 30):
        open(os.path.join(data, 'MISS%d.RES' % n), 'wb').write(b'x')
    try:
        MP.make_save(tnova, 1)
        check(False, 'no save of the player: refused')
    except MP.PlayError as e:
        check('at least one save' in str(e), 'no save of the player: refused (%s)' % e)
    save(tnova, 1, 'Early', 37, 3)
    save(tnova, 2, 'Late', 30, 38)
    save(tnova, 4, 'COOP Mission 05', 3, 7)
    before = md5s(tnova)
    label, path = MP.make_save(tnova, 1)
    check(label == 'UPLINK Mission 03' and os.path.basename(path) == 'SAVE03.RES', 'a campaign mission: %s in %s' % (label, os.path.basename(path)))
    r = lgres.load(path)
    h = struct.unpack('<6i', r[1776][2])
    check(h[1] == 1 and h[2] == MP.CAMPAIGN.index(1) + 3 and h[0] == MP.MAGIC and h[3:] == (8275, 37, 135), 'its header is on mission 1: %s' % (h,))
    raw = {e[0]: e for e in MP._raw(path)}
    check(raw[1777][1] == 1 and raw[1777][3] == 384 and raw[1777][4] == bytes(range(112)), 'the packed resource is the most advanced save\'s, as stored')
    check({k: v for k, v in md5s(tnova).items() if k != 'SAVE03.RES'} == before, 'no other save changed')
    label2, path2 = MP.make_save(tnova, 30)
    check(path2 == path and label2 == 'UPLINK Mission %02d' % (MP.CAMPAIGN.index(30) + 1), 'the next one takes our own slot again')
    try:
        MP.make_save(tnova, 18)
        check(False, 'a new mission that is not installed: refused')
    except MP.PlayError as e:
        check('install the new mission first' in str(e), 'a new mission that is not installed: refused (%s)' % e)
    open(os.path.join(data, 'MISS18.RES'), 'wb').write(b'x')
    label3, path3 = MP.make_save(tnova, 18)
    h = struct.unpack('<6i', lgres.load(path3)[1776][2])
    check(label3 == 'UPLINK Mission new 18' and h[1] == 18 and h[2] == 38, 'a new mission keeps the save\'s campaign position: %s %s' % (label3, h[:3]))
    try:
        MP.make_save(tnova, 99)
        check(False, 'mission 99: refused')
    except MP.PlayError:
        check(True, 'mission 99: refused')
    os.remove(path3)
    for slot in (3, 5, 6, 7, 8, 9):
        save(tnova, slot, 'Mine %d' % slot, 37, 3)
    before = md5s(tnova)
    try:
        MP.make_save(tnova, 1)
        check(False, 'nine slots used: refused')
    except MP.PlayError as e:
        check('9 save slots' in str(e) and md5s(tnova) == before, 'nine slots used: refused, nothing written')
    lst = MP.saves(tnova)
    check(len(lst) == 9 and [s['ours'] for s in lst].count(True) == 1 and MP.ROW_Y(5) == 232 and MP.ROW_Y(9) == 393, 'the list of saves, and their rows')
print('%d failed' % fails)
sys.exit(1 if fails else 0)
