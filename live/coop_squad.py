# Co-op: the guest's suit kept in an AI group of its own, so that the host's squad orders reach the other squadmates.
#
# The game moves its squad by groups (0x3804F0, 0x170 bytes each, +0x10 how many brains; the brains 0x3832F0, 0x14E each,
# +6 their group): an order to the entire squad goes to each group, and a group carries it out through its brains. The
# TN+ coop code no longer updates the brain of the suit the guest drives (its AI hook skips it, its messages drained),
# and a group holding that brain left the order undone: told "move there" or "follow me", the two other squadmates
# stood still for as long as the guest played (measured, mission 30: 0 of 2 moved in 30 s; with the coop code off they
# went at once). The game itself puts a squadmate in a group of his own when he alone is given an order (seen: the
# guest's brain from group 15 to a new group 16, the two others left in 15): the same "move there" was then carried
# out by both. So, while a guest plays, the bridge gives his squadmate alone "hold position" with the game's own COMM
# keys (orders.py) whenever his brain shares its group. (Not "follow me": a group following the player is put back with
# the others by the next order to the entire squad, which the game then sends while the brain is moved again: one
# squadmate was left behind.) When the guest leaves that suit (another one, or the end of his play), it is given
# "follow me" alone: back to its AI, it follows the host.
import time

import orders

EVERY = 2.0                       # seconds between two looks

_o = None
_t = 0.0
_said = None
_apart = 0                        # the suit last kept apart
_seen = 0                         # looks in a row that found it sharing a group


def _k(o, e):
    n, mates = o.squad()
    return next((k for k, m, p in mates if m == e), None)


def keep_apart(gid, make, log=print):
    """gid: the guest's suit (0 none); make(): the bridge's Orders (the order wheel's when there is one)"""
    global _o, _t, _said, _apart, _seen
    now = time.time()
    if now - _t < EVERY or (not gid and not _apart):
        return
    _t = now
    try:
        if _o is None:
            _o = make()
        o = _o
        if o is None or not o.ok or o.groups is None or o.busy.locked():
            return
        if _apart and _apart != gid:                   # he left that suit: following the host again
            k = _k(o, _apart)
            if k is not None:
                log('coop: suit %d left by the guest: given "follow me" alone' % _apart)
                o.send(orders.FOLLOW, k)
            _apart, _seen = 0, 0
            return
        b = o.u8(o.master + 0x25 * gid + 0x21)
        if not b:
            return
        grp = o.u8(o.ai + 0x14E * b + 6)
        if o.u8(o.groups + 0x170 * grp + 0x10) <= 1:
            _apart, _seen = gid, 0
            return
        _seen += 1
        if _apart == gid and _seen < 2:                # (put back with others just now: an order may be on its way)
            return
        k = _k(o, gid)
        if k is None:
            return
        if _said != (gid, grp):
            _said = (gid, grp)
            log('coop: the guest\'s suit %d shares AI group %d: given "hold position" alone (a group of its own)' % (gid, grp))
        o.send(orders.HOLD, k)
        _apart, _seen = gid, 0
    except Exception as ex:
        if _said != repr(ex):
            _said = repr(ex)
            log('coop: squad groups: %r' % (ex,))
