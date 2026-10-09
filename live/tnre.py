# ============================================================
#  tnre.py - boite a outils de reverse engineering "maison"
#  pour Terra Nova sous DOSBox Staging (sans Cheat Engine)
#
#  - lit/ecrit la RAM emulee du DOS (ReadProcessMemory)
#  - injecte des touches au niveau scancode (SendInput)
#  - capture la fenetre DOSBox
#
#  Noms de touches = positions physiques QWERTY US (scancodes),
#  car DOSBox lit la position physique des touches.
#
#  Usage : python tnre.py find | snap NOM | shot NOM
#          python tnre.py keys "esc,wait:2,hold:w:1.5,enter"
#          python tnre.py dd ADRESSE_HEX [N]   (dump dwords)
#          python tnre.py wd ADRESSE_HEX VALEUR_HEX...  (ecrit dwords)
# ============================================================
import ctypes, ctypes.wintypes as wt, os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SNAPS = os.path.join(HERE, 'snaps')
SHOTS = os.path.join(HERE, 'shots')
MEMSIZE = 30 * 1024 * 1024          # memsize = 30 dans la config Staging
BIOS_DATE_OFF = 0xFFFF5             # DOSBox ecrit "01/01/92" ici

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
u32 = ctypes.WinDLL('user32', use_last_error=True)
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass


class MBI(ctypes.Structure):
    _fields_ = [('BaseAddress', ctypes.c_uint64), ('AllocationBase', ctypes.c_uint64),
                ('AllocationProtect', wt.DWORD), ('PartitionId', wt.WORD),
                ('RegionSize', ctypes.c_uint64), ('State', wt.DWORD),
                ('Protect', wt.DWORD), ('Type', wt.DWORD)]


k32.OpenProcess.restype = wt.HANDLE
k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(MBI), ctypes.c_size_t]
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.c_void_p,
                                  ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.WriteProcessMemory.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.c_void_p,
                                   ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
u32.GetForegroundWindow.restype = ctypes.c_void_p
u32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
u32.BringWindowToTop.argtypes = [ctypes.c_void_p]
u32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
u32.IsIconic.argtypes = [ctypes.c_void_p]
u32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(wt.DWORD)]
u32.GetClientRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(wt.RECT)]
u32.ClientToScreen.argtypes = [ctypes.c_void_p, ctypes.POINTER(wt.POINT)]
u32.IsWindowVisible.argtypes = [ctypes.c_void_p]
u32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]


# ---------------------------------------------------------------- processus
def dosbox_pid():
    """TNRE_PID (env) = ce DOSBox-la, sans repli ; sinon le seul DOSBox ouvert, ou la session de test
    (perf_pid.txt) quand il y en a plusieurs."""
    import psutil
    want = os.environ.get('TNRE_PID')
    if want:
        if psutil.pid_exists(int(want)):
            return int(want)
        raise SystemExit('DOSBox Staging ne tourne pas (pid %s)' % want)
    pids = [p.pid for p in psutil.process_iter(['name']) if 'dosbox' in (p.info['name'] or '').lower()]
    if not pids:
        raise SystemExit('DOSBox Staging ne tourne pas')
    if len(pids) > 1:
        f = os.path.join(HERE, 'perf_pid.txt')
        mine = int(open(f).read().strip() or 0) if os.path.exists(f) else 0
        if mine in pids:
            return mine
        raise SystemExit('plusieurs DOSBox ouverts : definir TNRE_PID')
    return pids[0]


class Guest:
    """Acces a la RAM physique emulee (adresses lineaires du DOS)."""

    def __init__(self):
        self.pid = dosbox_pid()
        self.h = k32.OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x0400, False, self.pid)
        if not self.h:
            raise SystemExit('OpenProcess a echoue (%d)' % ctypes.get_last_error())
        self.base = self._cached_base() or self._find_base()

    def _raw_read(self, addr, n):
        buf = ctypes.create_string_buffer(n)
        got = ctypes.c_size_t()
        if not k32.ReadProcessMemory(self.h, addr, buf, n, ctypes.byref(got)):
            return None
        return buf.raw[:got.value]

    def _cached_base(self):
        f = os.path.join(HERE, 'base.txt')
        if os.path.exists(f):
            pid, base = open(f).read().split()
            if int(pid) == self.pid:
                base = int(base, 16)
                if self._raw_read(base + BIOS_DATE_OFF, 8) == b'01/01/92':
                    return base
        return None

    def _find_base(self):
        addr = 0
        m = MBI()
        while k32.VirtualQueryEx(self.h, addr, ctypes.byref(m), ctypes.sizeof(m)):
            if m.State == 0x1000 and m.RegionSize >= 8 * 1024 * 1024:
                buf = self._raw_read(m.BaseAddress, m.RegionSize)
                if buf:
                    i = buf.find(b'01/01/92')
                    while i != -1:
                        b = i - BIOS_DATE_OFF
                        if b >= 0 and b + 0x100000 <= len(buf):
                            base = m.BaseAddress + b
                            open(os.path.join(HERE, 'base.txt'), 'w').write('%d %x' % (self.pid, base))
                            return base
                        i = buf.find(b'01/01/92', i + 1)
            addr = m.BaseAddress + m.RegionSize
        raise SystemExit('RAM emulee introuvable')

    def read(self, lin, n):
        return self._raw_read(self.base + lin, n)

    def write(self, lin, data):
        got = ctypes.c_size_t()
        buf = ctypes.create_string_buffer(bytes(data), len(data))
        ok = k32.WriteProcessMemory(self.h, self.base + lin, buf, len(data), ctypes.byref(got))
        if not ok:
            raise SystemExit('WriteProcessMemory a echoue (%d)' % ctypes.get_last_error())

    def snapshot(self):
        taille = MEMSIZE
        while taille > 0x100000:
            d = self.read(0, taille)
            if d:
                return d
            taille -= 0x100000                  # memsize plus petit (ex. DOSBox 0.74 a 16 Mo)
        return self.read(0, taille)

    def dword(self, lin):
        return struct.unpack('<i', self.read(lin, 4))[0]

    def set_dword(self, lin, v):
        self.write(lin, struct.pack('<i', v))


# ---------------------------------------------------------------- fenetre
def dosbox_window():
    pid = dosbox_pid()
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, ctypes.c_void_p, ctypes.c_void_p)
    def cb(hwnd, _):
        p = wt.DWORD()
        u32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and u32.IsWindowVisible(hwnd):
            t = ctypes.create_unicode_buffer(256)
            u32.GetWindowTextW(hwnd, t, 256)
            if t.value and 'IME' not in t.value and 'MSCTF' not in t.value:
                found.append(hwnd)
        return True

    u32.EnumWindows(cb, 0)
    if not found:
        raise SystemExit('fenetre DOSBox introuvable')
    return found[0]


def focus():
    hwnd = dosbox_window()
    fg = u32.GetForegroundWindow()
    if fg != hwnd:
        if u32.IsIconic(hwnd):
            u32.ShowWindow(hwnd, 9)
        t_fg = u32.GetWindowThreadProcessId(fg, None) if fg else 0
        t_me = k32.GetCurrentThreadId()
        if t_fg:
            u32.AttachThreadInput(t_me, t_fg, True)
        u32.BringWindowToTop(hwnd)
        u32.SetForegroundWindow(hwnd)
        if t_fg:
            u32.AttachThreadInput(t_me, t_fg, False)
        time.sleep(0.15)
    return hwnd


def shot_bg(name, width=640):
    """Capture sans voler le focus (PrintWindow + PW_RENDERFULLCONTENT)."""
    from PIL import Image
    g32 = ctypes.WinDLL('gdi32')
    hwnd = dosbox_window()
    r = wt.RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    w, h = r.right, r.bottom
    u32.GetDC.restype = ctypes.c_void_p
    u32.GetDC.argtypes = [ctypes.c_void_p]
    g32.CreateCompatibleDC.restype = ctypes.c_void_p
    g32.CreateCompatibleDC.argtypes = [ctypes.c_void_p]
    g32.CreateCompatibleBitmap.restype = ctypes.c_void_p
    g32.CreateCompatibleBitmap.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    g32.SelectObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    g32.GetDIBits.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wt.UINT, wt.UINT,
                              ctypes.c_void_p, ctypes.c_void_p, wt.UINT]
    g32.DeleteObject.argtypes = [ctypes.c_void_p]
    g32.DeleteDC.argtypes = [ctypes.c_void_p]
    u32.ReleaseDC.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    u32.PrintWindow.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wt.UINT]
    hdc = u32.GetDC(hwnd)
    mdc = g32.CreateCompatibleDC(hdc)
    bmp = g32.CreateCompatibleBitmap(hdc, w, h)
    g32.SelectObject(mdc, bmp)
    u32.PrintWindow(hwnd, mdc, 3)            # PW_CLIENTONLY | PW_RENDERFULLCONTENT
    bmi = struct.pack('<IiiHHIIiiII', 40, w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    g32.GetDIBits(mdc, bmp, 0, h, buf, bmi, 0)
    g32.DeleteObject(bmp)
    g32.DeleteDC(mdc)
    u32.ReleaseDC(hwnd, hdc)
    img = Image.frombuffer('RGB', (w, h), buf.raw, 'raw', 'BGRX', 0, 1)
    if width:
        img = img.resize((width, width * 3 // 4))
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name + '.png')
    img.save(path)
    return path


def shot(name, width=640):
    from PIL import ImageGrab
    hwnd = focus()
    r = wt.RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    p = wt.POINT(0, 0)
    u32.ClientToScreen(hwnd, ctypes.byref(p))
    img = ImageGrab.grab(bbox=(p.x, p.y, p.x + r.right, p.y + r.bottom), all_screens=True)
    if width:
        img = img.resize((width, width * 3 // 4))
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name + '.png')
    img.save(path)
    return path


# ---------------------------------------------------------------- clavier
class KEYBDINPUT(ctypes.Structure):
    _fields_ = [('wVk', wt.WORD), ('wScan', wt.WORD), ('dwFlags', wt.DWORD),
                ('time', wt.DWORD), ('dwExtraInfo', ctypes.c_uint64)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [('dx', wt.LONG), ('dy', wt.LONG), ('mouseData', wt.DWORD),
                ('dwFlags', wt.DWORD), ('time', wt.DWORD), ('dwExtraInfo', ctypes.c_uint64)]


class _IU(ctypes.Union):
    _fields_ = [('ki', KEYBDINPUT), ('mi', MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [('type', wt.DWORD), ('u', _IU)]


SC = {'esc': 0x01, 'enter': 0x1C, 'space': 0x39, 'tab': 0x0F, 'bksp': 0x0E,
      'lshift': 0x2A, 'rshift': 0x36, 'lctrl': 0x1D, 'lalt': 0x38,
      'up': 0xE048, 'down': 0xE050, 'left': 0xE04B, 'right': 0xE04D,
      'pgup': 0xE049, 'pgdn': 0xE051, 'home': 0xE047, 'end': 0xE04F,
      'ins': 0xE052, 'del': 0xE053,
      'kp8': 0x48, 'kp2': 0x50, 'kp4': 0x4B, 'kp6': 0x4D, 'kp5': 0x4C,
      'minus': 0x0C, 'equal': 0x0D, 'lbr': 0x1A, 'rbr': 0x1B, 'semi': 0x27,
      'quote': 0x28, 'grave': 0x29, 'bslash': 0x2B, 'comma': 0x33, 'dot': 0x34, 'slash': 0x35}
for i, c in enumerate('1234567890'):
    SC[c] = 0x02 + i
for row, start in (('qwertyuiop', 0x10), ('asdfghjkl', 0x1E), ('zxcvbnm', 0x2C)):
    for i, c in enumerate(row):
        SC[c] = start + i
for i in range(10):
    SC['f%d' % (i + 1)] = 0x3B + i
SC['f11'], SC['f12'] = 0x57, 0x58


def click(x, y, ref_width=640):
    """Clic gauche aux coordonnees (x, y) d'une capture de largeur ref_width
    (necessite mouse_capture = seamless)."""
    hwnd = focus()
    r = wt.RECT()
    u32.GetClientRect(hwnd, ctypes.byref(r))
    kx, ky = r.right / ref_width, r.bottom / (ref_width * 3 / 4)
    p = wt.POINT(int(x * kx), int(y * ky))
    u32.ClientToScreen(hwnd, ctypes.byref(p))
    u32.SetCursorPos(p.x, p.y)
    time.sleep(0.15)
    for flag in (0x0001, 0x0002, 0x0004):  # petit MOVE (reveille la souris DOS), LEFTDOWN, LEFTUP
        inp = INPUT(type=0)
        inp.u.mi = MOUSEINPUT(1 if flag == 1 else 0, 0, 0, flag, 0, 0)
        u32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.25 if flag == 1 else 0.08)


WM_KEYDOWN, WM_KEYUP, WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x100, 0x101, 0x200, 0x201, 0x202
u32.PostMessageW.argtypes = [ctypes.c_void_p, wt.UINT, ctypes.c_size_t, ctypes.c_ssize_t]
u32.MapVirtualKeyW.argtypes = [wt.UINT, wt.UINT]
POST = os.environ.get('TNRE_POST') == '1'


def _post_key(sc, up):
    hwnd = dosbox_window()
    vk = u32.MapVirtualKeyW(sc & 0xFF, 1) or 0
    if sc & 0xE000:
        vk = {0x48: 0x26, 0x50: 0x28, 0x4B: 0x25, 0x4D: 0x27, 0x49: 0x21, 0x51: 0x22, 0x47: 0x24, 0x4F: 0x23,
              0x52: 0x2D, 0x53: 0x2E}.get(sc & 0xFF, vk)
    lp = 1 | ((sc & 0xFF) << 16) | ((1 << 24) if sc & 0xE000 else 0)
    if up:
        lp |= 0xC0000000
    u32.PostMessageW(hwnd, WM_KEYUP if up else WM_KEYDOWN, vk, ctypes.c_ssize_t(lp - (1 << 32) if lp >= 1 << 31 else lp).value)


def post_click(cx, cy):
    """Clic gauche envoye a la fenetre (coordonnees client), sans toucher au vrai curseur."""
    hwnd = dosbox_window()
    lp = (cy << 16) | (cx & 0xFFFF)
    u32.PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp); time.sleep(0.05)
    u32.PostMessageW(hwnd, WM_LBUTTONDOWN, 1, lp); time.sleep(0.08)
    u32.PostMessageW(hwnd, WM_LBUTTONUP, 0, lp)


def _key(sc, up):
    if POST:
        return _post_key(sc, up)
    flags = 0x0008 | (0x0002 if up else 0) | (0x0001 if sc & 0xE000 else 0)
    inp = INPUT(type=1)
    inp.u.ki = KEYBDINPUT(0, sc & 0xFF, flags, 0, 0)
    u32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def hold(names, seconds):
    codes = [SC[n] for n in names.split('+')]
    for c in codes:
        _key(c, False)
    time.sleep(seconds)
    for c in reversed(codes):
        _key(c, True)
    time.sleep(0.05)


def keys(seq):
    """"esc,wait:2,hold:w:1.5,lctrl+f11,enter" """
    if not POST:
        focus()
    for step in seq.split(','):
        step = step.strip()
        if not step:
            continue
        if step.startswith('wait:'):
            time.sleep(float(step[5:]))
        elif step.startswith('hold:'):
            _, k, s = step.split(':')
            hold(k, float(s))
        elif step.startswith('click:'):
            _, x, y = step.split(':')
            click(int(x), int(y))
            time.sleep(0.2)
        else:
            hold(step, 0.08)
            time.sleep(0.12)


# ---------------------------------------------------------------- CLI
def main(a):
    cmd = a[0]
    if cmd == 'find':
        g = Guest()
        print('pid %d  RAM emulee a 0x%x' % (g.pid, g.base))
    elif cmd == 'snap':
        g = Guest()
        os.makedirs(SNAPS, exist_ok=True)
        open(os.path.join(SNAPS, a[1] + '.bin'), 'wb').write(g.snapshot())
        print('snap', a[1])
    elif cmd == 'walk':
        # walk PREFIXE TOUCHE N INTERVALLE : maintient TOUCHE et prend N dumps
        g = Guest()
        prefix, key, n, dt = a[1], a[2], int(a[3]), float(a[4])
        focus()
        codes = [SC[k] for k in key.split('+')]
        for c in codes:
            _key(c, False)
        time.sleep(0.3)
        snaps = []
        for i in range(n):
            snaps.append(g.snapshot())
            time.sleep(dt)
        for c in reversed(codes):
            _key(c, True)
        os.makedirs(SNAPS, exist_ok=True)
        for i, s in enumerate(snaps):
            open(os.path.join(SNAPS, '%s%d.bin' % (prefix, i)), 'wb').write(s)
        print('%d dumps %s0..%d' % (n, prefix, n - 1))
    elif cmd == 'shot':
        print(shot(a[1], int(a[2]) if len(a) > 2 else 640))
    elif cmd == 'vue':
        print(shot_bg(a[1], int(a[2]) if len(a) > 2 else 640))
    elif cmd == 'keys':
        keys(a[1])
    elif cmd == 'dd':
        g = Guest()
        lin, n = int(a[1], 16), int(a[2]) if len(a) > 2 else 16
        for i in range(n):
            v = g.dword(lin + 4 * i)
            print('%08x: %08x  %11d  %10.4f' % (lin + 4 * i, v & 0xffffffff, v, v / 65536))
    elif cmd == 'wd':
        g = Guest()
        lin = int(a[1], 16)
        for i, v in enumerate(a[2:]):
            g.set_dword(lin + 4 * i, int(v, 16) if not v.startswith('-') else int(v))
        print('ok')
    else:
        print(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
