# Pont vers Terra Nova Uplink (mode --live) : lit la camera du jeu qui tourne (lecture seule) et l'envoie en UDP
# (127.0.0.1:47821) : x, y, z (unites du jeu), cap camera et inclinaison (radians), champ horizontal (degres).
# Adresses retrouvees par la signature "camera" de TNPlus (id du joueur, table des objets, cap camera, tangage).
#   python live_bridge.py [--fov 91.5] [--eye 0.32] [--hz 120] [--once] [--launch [--res 1600x900 | --res native]]
#   --launch : retrouve la mission en cours (nom MISSnn.RES en memoire), lance Uplink dessus en mode
#   --live et le pilote jusqu'a sa fermeture.   (TNRE_PID = DOSBox du jeu s'il y en a plusieurs)
import math, os, re, select, socket, struct, sys, time, zlib
import tnre

g = tnre.Guest()
arg = lambda k, d: float(sys.argv[sys.argv.index(k) + 1]) if k in sys.argv else d
FOV, EYE, HZ = arg('--fov', 100.0), arg('--eye', 0.32), arg('--hz', 120.0)   # oeil : 0.32 au-dessus de l'entite du joueur (ajuste sur la poussiere d'un tir laser, a 0.5 px pres)
NENT = 300                               # entrees lues dans la table des entites
HUD, PLAY = '--hud' in sys.argv, '--play' in sys.argv   # avant --launch, qui les passe au visualiseur
CAM = None
if '--cam' in sys.argv:
    _c = [float(v) for v in sys.argv[sys.argv.index('--cam') + 1].split(',')]
    CAM = (_c[0], _c[1], _c[2], math.radians(_c[3]), math.radians(_c[4]))

# "8b15 (....) c1fa10 8d04d500000000 01d0 c1e002 01d0 05 (....) 668b15 (....) 668b401b 01d0 66a3 (....) 66a1 (....) 66a3 (....)"
SIG = re.compile(re.escape(bytes.fromhex('8b15')) + b'(....)' + re.escape(bytes.fromhex('c1fa108d04d50000000001d0c1e00201d005')) +
                 b'(....)' + re.escape(bytes.fromhex('668b15')) + b'(....)' + re.escape(bytes.fromhex('668b401b01d066a3')) +
                 b'(....)' + re.escape(bytes.fromhex('66a1')) + b'(....)' + re.escape(bytes.fromhex('66a3')) + b'(....)', re.S)
code = g.read(0x200000, 0x140000)
caps = [[struct.unpack('<I', m.group(i))[0] for i in range(1, 7)] for m in SIG.finditer(code)]
caps = [c for c in caps if all(0x300000 <= v < 0x500000 for v in c)]   # le code reloge (pas une copie brute)
assert caps, 'signature camera introuvable'
cap = caps[0]
A_PID, A_MASTER, A_HEADYAW, A_CAMHEAD, A_PITCH, A_CAMPITCH = cap
print('camera : id %#x, objets %#x, cap camera %#x, tangage tete %#x, tangage camera %#x' % (A_PID, A_MASTER, A_CAMHEAD, A_PITCH, A_CAMPITCH))
# exe francais (GOG francise) ou anglais (Steam / GOG anglais) : memes routines, donnees decalees de 0xB0
FR = A_MASTER == 0x3C32F0
SOLDATS = 0x3A56B8 if FR else 0x3A5608   # fiches soldats, 0x582 octets
print('exe %s' % ('francais' if FR else 'anglais'))

viewer = None
if '--launch' in sys.argv:
    import collections, os, subprocess
    data = g.read(0x340000, 0x140000)
    names = collections.Counter(m.group().decode().upper() for m in re.finditer(rb'miss\d+\.res', data, re.I))
    mission = names.most_common(1)[0][0] if names else None   # lance depuis les menus : la mission suit ('MIS')
    res = sys.argv[sys.argv.index('--res') + 1] if '--res' in sys.argv else '1600x900'
    godot = os.environ.get('GODOT', r'C:\Tools\Godot\Godot_v4.7.2-stable_win64.exe')
    vpath = os.environ.get('TN_VIEWER', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # le depot
    print('mission', mission, '-> Uplink', res)
    pos = ['--position', os.environ['TN_POS']] if 'TN_POS' in os.environ else []   # tests : fenetre hors ecran
    taille = ['--', '--live', '--native'] if res == 'native' else ['--resolution', res] + pos + ['--', '--live']   # native : plein ecran
    viewer = subprocess.Popen([godot, '--path', vpath] + taille + (['--mission', mission] if mission else []) + (['--hud'] if HUD else []) + (['--play'] if PLAY else []) +
                              (['--coop-host'] if '--guest' in sys.argv or '--guest-remote' in sys.argv else []))
    print('visualiseur pid %d' % viewer.pid, flush=True)
    if '--guest' in sys.argv:                   # coop: the guest's window (same Uplink, other ports, no HUD)
        import coop_guest
        gviewer = coop_guest.launch(godot, vpath, mission)
        print('guest window pid %d' % gviewer.pid, flush=True)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# HUD (--hud) : l'ecran du jeu 320 x 400 (tampon factice du mode HD) avec la 3D rendue transparente, comme le fait
# le code HD pour poser sa 3D (un pixel de la fenetre 3D est de la 3D s'il est egal au pixel de l'image HD a la
# colonne double). Port 47823 : un paquet 'PAL' (palette 768 o + fenetre 3D FX0 FY0 FW FH en mots), puis 5 paquets
# 'HUD' de 80 lignes (index, alpha) par image, ~30 par seconde.
HUD = '--hud' in sys.argv
HB, SB, VA, FX, FY, FWV, FHV, FWWV, FSI = 0x466100, 0x46612C, 0x466134, 0x4661A8, 0x4661AC, 0x4661B0, 0x4661B4, 0x4661B8, 0x466208
PAL = 0x44AF40 if FR else 0x44AE90        # palette de l'ecran du jeu
VEG = 0x3C5ECC if FR else 0x3C5E1C        # carte de vegetation en cours (128 x 128) : un arbre detruit vide sa case
veg_prev, veg_t, veg_sent = None, 0.0, 0.0
# carte du sol de la mission (513 x 513 sommets de 3 octets : tuile, hauteur), pointee depuis les donnees fixes : le
# jeu allume le bit 0x40 de la tuile d'un sommet brule (arbre detruit, explosion) ; le pointeur valable est celui
# dont la hauteur sous le joueur est la sienne
SOL_PTRS = (0x36F5BA, 0x36FDC2) if FR else (0x36F50A, 0x36FD12)
BRULE = re.compile(b'[' + bytes([0x40]) + b'-' + bytes([0x7f]) + bytes([0xc0]) + b'-' + bytes([0xff]) + b']', re.S)
brule_prev, brule_t, brule_sent = None, 0.0, 0.0
# nuages : decalage de la texture du ciel (texels 16.16, u puis v), qui avance avec le vent ; la position du joueur
# s'y ajoute a l'affichage (plafond a 44 unites au-dessus de l'oeil, 1 texel par unite)
NUAGES = 0x427E6C if FR else 0x427DBC
# vue infrarouge du jeu (touche I) : 1 = IR (0x38A3FE dans l'exe francais, retrouve sur l'image ; anglais suppose a
# -0xB0 comme la camera principale voisine, pas verifie)
INFRA = 0x38A3FE if FR else 0x38A34E
# vues annexes du HUD (camera du soldat selectionne en bas a gauche : bouton VUE ; camera de la sonde a droite) : le
# jeu les dessine avec le point de vue partage de ses vues secondaires (0x41EB68 dans l'exe anglais, x, y, z 16.16),
# qui ne tient leur position que le temps de leur dessin (le reste du temps : celle du joueur). Lu en rafale a chaque
# tour ; son entite (mot a +0x5A : equipier ou sonde ; le joueur = la vue principale) dit laquelle. Cadres dans l'ecran 320 x 400 : VUE (17, 276)-(99, 380), sonde
# (217, 264)-(299, 368) (regions 1 et 3 de la table 0x389DF8).
#   'SUBV' + n (u8) + n x [panneau (u8 : 1 VUE, 2 cible, 3 sonde), entite (i32), x, y, z, cap, tangage, zoom (f32),
#   cadre x0, y0, x1, y1 (i16)]
VUEPT = 0x41EC18 if FR else 0x41EB68
MODES = 0x38FCC2 if FR else 0x38FC12     # mode des panneaux du cockpit (octet, pas de 32) : 4 VUE, 0x15 camera de cible
CAMS = 0x3900C0 if FR else 0x390010      # cameras des panneaux (pas de 0xBA) : zoom 16.16 en tete
REGIONS = 0x389EA8 if FR else 0x389DF8   # table des cadres des panneaux du cockpit en cours (pointeurs ; x0, y0, x1, y1 a +8)


def cadres():
    """cadres des panneaux du bas (y0 > 200) du cockpit en cours, de gauche a droite (ils changent d'une armure a l'autre)"""
    out = []
    for k in range(8):
        p = struct.unpack('<I', g.read(REGIONS + 4 * k, 4))[0]
        if not 0x380000 <= p < 0x3A0000: continue
        r = struct.unpack('<4h', g.read(p + 8, 8))
        if r[1] > 200 and 40 < r[2] - r[0] < 120: out.append(r)
    return sorted(out)
OEIL = 0x38FBCC if FR else 0x38FB1C    # hauteur de l'oeil ajoutee par le jeu (16.16)
vues = {}                                 # panneau -> (temps, entite, x, y, z, cap)
nuages_t = 0.0
# soldats morts : leur corps eclate en morceaux d'armure (entites 6/33) ; une table par numero de soldat n garde leur
# position apres la mort (0x38337F + n * 0x14E dans l'exe francais), la fiche soldat leur armure (+0xDE)
CORPS = 0x38337F if FR else 0x3832CF
corps_t, corps = 0.0, []


def armure_debris(x, y, vivants):
    best, arm = 3.0, -1
    for n, cx, cy in corps:
        if n in vivants: continue
        d = math.hypot(cx - x, cy - y)
        if d < best:
            best, arm = d, n
    if arm < 0: return -1
    return struct.unpack('<I', g.read(SOLDATS + arm * 0x582 + 0xDE, 4))[0]
d32 = lambda a: struct.unpack('<i', g.read(a, 4))[0]
hud_t = 0.0

# Zoom du jeu (touches HUD zoom + / -) : la camera principale (0x38FB24 dans l'exe anglais, 0x38FBD4 en francais)
# tient un zoom effectif, et tan(champ / 2) suit 1 / zoom ; le plus petit zoom vu (vue normale) vaut --fov.
A_ZOOM = 0x38FBD4 if FR else 0x38FB24     # (lance depuis les menus : pas encore de camera a reconnaitre)


ZOOM_NORMAL = 0.88916                      # zoom de la vue normale (0xE3A0), ou le champ vaut --fov


def fov_now():
    # le jeu tient tan(demi-champ) = 1 / zoom (l'angle a +0x18) : le champ suit le zoom lu, sans reference a suivre
    # (le plus petit zoom vu servait de reference : une valeur basse passagere zoomait la vue de Godot pour de bon)
    z = d32(A_ZOOM) / 65536 if A_ZOOM else 0
    if not 0.05 < z < 50: return FOV
    return math.degrees(2 * math.atan(math.tan(math.radians(FOV / 2)) * ZOOM_NORMAL / z))
hud_n = 0
hud_copies = -1
COPIES = 0x46613C                          # compteur d'images affichees du code HD

# Jouer depuis la fenetre du visualiseur (--play) : il renvoie clavier et souris sur le port 47824.
#   'K' + scancode (u16, 0xE0xx = touche etendue) + appui (u8) -> touche postee a la fenetre DOSBox (position physique,
#        donc presets / remappage de TNPlus inchanges ; Alt en WM_SYSKEY comme le ferait Windows)
#   'M' + dx, dy (i16)  -> regard comme le freelook de TNPlus : cap += dx * 12, tangage += dy * 8 (bornes du jeu),
#        curseur du jeu tenu au centre de la vue (ou partent les tirs)
#   'B' + bouton (1 gauche, 2 droit) + appui -> evenement dans la file de la lib souris du jeu (tir, verrouillage)
#   'P' + x, y (i16)  -> regard coupe (Y ou Pause dans le visualiseur) : curseur du jeu a cette position de son
#        ecran 320 x 400 (boutons du HUD, carte, visee libre)
#   'C' + bouton + appui + x, y -> clic a cette position
#   'HOST' -> bouton "Host online" du visualiseur : coop en ligne a partir de maintenant (comme --guest-remote)
PLAY = '--play' in sys.argv
SENS_X, SENS_Y, PITCH_MIN, PITCH_MAX = 12, 8, -7187, 6127
if PLAY:
    import ctypes
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(('127.0.0.1', 47824))
    rx.setblocking(False)
    u32w = ctypes.windll.user32
    win = tnre.dosbox_window()
    code2 = g.read(0x2f0000, 0x20000)
    m_lect, m_fil = [struct.unpack('<I', v)[0] for v in re.search(rb'\x0f\xbf\x35(....)\xc1\xe6\x04\x8d\xb6(....)', code2, re.S).groups()]
    m_taille = struct.unpack('<I', re.search(rb'\x0f\xbf\x3d(....)\xa1(....)\x47\xc1\xf8\x10', code2, re.S).group(2))[0] + 2
    m_horloge = struct.unpack('<I', re.search(rb'\x8b\x0d(....)\x8b\x09\x89\x8e', g.read(0x300000, 0x40000), re.S).group(1))[0]
    big = g.read(0x200000, 0x140000)
    reloge = lambda ms: [[struct.unpack('<I', v)[0] for v in m.groups()] for m in ms if all(0x300000 <= struct.unpack('<I', v)[0] < 0x500000 for v in m.groups())][0]
    m_warp, m_cur = reloge(re.finditer(rb'\x84\xd2\x0f\x85....\x80\x3d(....)\x00\x74\x23\x8b\x15(....)\xa1', big, re.S))   # souris : warp, curseur
    m_frame = reloge(re.finditer(rb'\x8b\x04\x24\x8b\x15(....)\xa3(....)\xa1', big, re.S))[1]                              # cadre du curseur
    alt = False
    print('jouer : fenetre DOSBox %#x, file souris %#x, curseur %#x, cadre %#x' % (win, m_fil, m_cur, m_frame))


def centre():
    w, h = struct.unpack('<hh', g.read(m_frame, 4))
    return (w // 2, int(round(h * 0.36))) if 200 <= w <= 640 and 200 <= h <= 480 else (160, 72)


def mouse_evt(ev, bt, pos=None):
    x, y = pos or centre()
    g.write(m_cur, struct.pack('<hh', x, y)); g.write(m_warp, b'\x01')
    w = struct.unpack('<H', g.read(m_lect - 4, 2))[0]
    n = struct.unpack('<H', g.read(m_taille, 2))[0]
    t = g.dword(g.dword(m_horloge))
    g.write(m_fil + 16 * w, struct.pack('<hhBIB', x, y, ev, t & 0xffffffff, bt).ljust(16, bytes(1)))
    g.write(m_lect - 4, struct.pack('<H', (w + 1) % n))


def post_key(sc, down):
    global alt
    if sc in (0x38, 0xE038): alt = down
    vk = u32w.MapVirtualKeyW(sc & 0xFF, 1) or 0
    if sc & 0xE000:
        vk = {0x48: 0x26, 0x50: 0x28, 0x4B: 0x25, 0x4D: 0x27, 0x49: 0x21, 0x51: 0x22, 0x47: 0x24, 0x4F: 0x23,
              0x52: 0x2D, 0x53: 0x2E, 0x1D: 0xA3, 0x38: 0xA5, 0x1C: 0x0D, 0x35: 0x6F}.get(sc & 0xFF, vk)
    lp = 1 | ((sc & 0xFF) << 16) | ((1 << 24) if sc & 0xE000 else 0) | ((1 << 29) if alt or sc in (0x38, 0xE038) else 0)
    if not down: lp |= 0xC0000000
    sys_ = alt or sc in (0x38, 0xE038)
    msg = (0x104 if down else 0x105) if sys_ else (0x100 if down else 0x101)
    u32w.PostMessageW(ctypes.c_void_p(win), msg, vk, ctypes.c_ssize_t(lp - (1 << 32) if lp >= 1 << 31 else lp).value)


def handle_input():
    global guest
    look = False
    while True:
        try:
            pk, _ = rx.recvfrom(64)
        except (BlockingIOError, OSError):
            break
        if pk[:1] == b'K' and len(pk) >= 4:
            sc, down = struct.unpack('<HB', pk[1:4])
            post_key(sc, bool(down))
        elif pk[:1] == b'M' and len(pk) >= 5:
            dx, dy = struct.unpack('<hh', pk[1:5])
            e = A_MASTER + u16(A_PID + 2) * 0x25
            if dx:
                g.write(e + 0x1B, struct.pack('<H', (u16(e + 0x1B) + dx * SENS_X) & 0xffff))
            if dy:
                g.write(A_PITCH, struct.pack('<h', max(PITCH_MIN, min(PITCH_MAX, s16(A_PITCH) + dy * SENS_Y))))
            look = True
        elif pk[:1] == b'B' and len(pk) >= 3:
            btn, down = pk[1], pk[2]
            if btn == 1: mouse_evt(2 if down else 4, 1 if down else 0)
            elif btn == 2: mouse_evt(8 if down else 16, 2 if down else 0)
        elif pk[:1] == b'P' and len(pk) >= 5:
            g.write(m_cur, pk[1:5]); g.write(m_warp, b'\x01')
        elif pk[:1] == b'C' and len(pk) >= 7:
            btn, down = pk[1], pk[2]
            pos = struct.unpack('<hh', pk[3:7])
            if btn == 1: mouse_evt(2 if down else 4, 1 if down else 0, pos)
            elif btn == 2: mouse_evt(8 if down else 16, 2 if down else 0, pos)
        elif pk == b'HOST' and guest is None:   # the viewer's "Host online" button: its coop_net.gd opens the lobby
            import coop_guest
            guest = coop_guest.Guest(g, A_MASTER, A_PID, NENT, EYE, SENS_X, fov_now, s, remote=True)
            print('coop: hosting online', flush=True)
    if look:                                  # le curseur du jeu reste au centre : on vise ou on regarde
        x, y = centre()
        g.write(m_cur, struct.pack('<hh', x, y)); g.write(m_warp, b'\x01')


hud_rate, hud_rect, hud_fixe = None, None, {}


def send_hud():
    import numpy as np
    global hud_n, hud_copies, hud_rate, hud_rect
    sbuf = d32(SB)
    if sbuf <= 0: return False
    # l'ecran du jeu et l'image HD doivent etre de la MEME image : juste apres un affichage (compteur qui avance),
    # avant le rendu suivant (ACTIVE), et rien de change pendant la lecture ; sinon la 3D du jeu passerait au travers
    c = d32(COPIES)
    if c == hud_copies or d32(0x466104): return False
    hud_copies = c                            # une seule tentative par image (elle ne se represente pas)
    scr = np.frombuffer(g.read(sbuf, 640 * 400), np.uint8).reshape(400, 640)[:, :320]
    alpha = np.full((400, 320), 255, np.uint8)
    fx0, fy0, fw, fh, fww, fside = d32(FX), d32(FY), d32(FWV), d32(FHV), d32(FWWV), d32(FSI)
    if 0 < fw <= 320 and 0 < fh <= 400 and fww > 0:
        hd = np.frombuffer(g.read(d32(HB), fww * fh), np.uint8).reshape(fh, fww)
        if d32(COPIES) != c or d32(0x466104): return False
        cols = np.arange(fx0, fx0 + fw)
        idx = 2 * cols - 2 * fx0 + fside
        ok = (idx >= 0) & (idx < fww)
        win = scr[fy0:fy0 + fh, fx0:fx0 + fw]
        same = np.zeros_like(win, bool)
        same[:, ok] = win[:, ok] == hd[:, idx[ok]]
        if same.mean() < 0.7: return False       # images qui ne correspondent pas : on garde le HUD precedent
        # une ligne entiere de la 3D qui differe alors que ses voisines correspondent : l'ecran du jeu et l'image HD lus
        # a un instant d'ecart pour cette ligne (vu au lancement de la sonde, en combat), pas un element du HUD (aucun
        # ne traverse la fenetre) ; opaque, elle montrait une rangee de gros pixels du jeu en travers de la vue
        if fh > 6:
            ligne = same[:, fw // 6:5 * fw // 6].mean(1)
            seule = np.zeros(fh, bool)
            seule[2:-2] = (ligne[2:-2] < 0.2) & (ligne[:-4] > 0.8) & (ligne[4:] > 0.8) & (ligne[1:-3] > 0.8) |                           (ligne[2:-2] < 0.2) & (ligne[:-4] > 0.8) & (ligne[4:] > 0.8) & (ligne[3:-1] > 0.8)
            same[seule] = True
        # un pixel du cadre du cockpit tombe parfois par hasard sur la couleur de la 3D derriere lui : transparent une
        # image, il faisait des trous qui scintillent sur les bords du cadre. Transparent seulement apres 3 images de
        # suite egales a la 3D ; un element du HUD qui apparait (lock, reticule) reste opaque des la premiere.
        # Le cadre reste pourtant egal a la 3D tant qu'elle a sa couleur (le gris du cadre sur la brume de
        # l'horizon) : des pixels du cadre devenaient transparents en marchant. Un pixel qui ne change pas depuis 30
        # images et qui a differe de la 3D pendant ce temps fait partie du cadre (ou d'un element fixe du HUD) : opaque.
        if hud_rect != (fx0, fy0, fw, fh):
            hud_rect, hud_rate = (fx0, fy0, fw, fh), np.full((fh, fw), 0.6, np.float32)
            hud_fixe.update(val=win.copy(), n=np.zeros((fh, fw), np.int32), diff=np.zeros((fh, fw), bool))
        bouge = win != hud_fixe['val']
        hud_fixe['val'] = win.copy()
        hud_fixe['n'][bouge] = 0; hud_fixe['diff'][bouge] = False
        hud_fixe['n'] += 1; hud_fixe['diff'] |= ~same
        cadre = (hud_fixe['n'] > 30) & hud_fixe['diff']
        hud_rate = hud_rate * 0.7 + same * 0.3
        alpha[fy0:fy0 + fh, fx0:fx0 + fw][same & (hud_rate > 0.6) & ~cadre] = 0
    else:
        fx0 = fy0 = fw = fh = 0
    if PLAY:
        curseur_hud(scr, alpha)
    hud_n += 1
    s.sendto(b'PAL' + struct.pack('<I4h', hud_n, fx0, fy0, fw, fh) + g.read(PAL, 768), ('127.0.0.1', 47823))
    rg = np.dstack([scr, alpha]).tobytes()
    z = zlib.compress(rg, 1)                  # cockpit et fenetre transparente : ~10x plus petit, un seul paquet
    if len(z) > 65000: return True            # (Windows ne garde que 64 Ko en attente sur la socket)
    s.sendto(b'HUZ' + struct.pack('<I', hud_n) + z, ('127.0.0.1', 47823))
    return True
# Le curseur du jeu dans sa 3D (souris liberee, Y ou Pause) : dessine dans l'ecran du jeu, donc dans le HUD, mais les
# vues annexes de Godot (equipier, sonde, cible) le recouvraient. Ses pixels sont marques alpha 254 (opaques pour le
# HUD) et les vues annexes les laissent passer. Son image (descripteur juste avant sa position : pointeur, type 2
# brute / 4 RLE, largeur, hauteur, pas) est retrouvee dans l'ecran autour de sa position (pointe relevee une fois).
cur3d = {}


def curseur_hud(scr, alpha):
    import numpy as np
    try:
        ptr, typ, _, w, h, row = struct.unpack('<IHHHHH', g.read(m_cur - 0x18, 14))
        if not (0x400000 <= ptr < 0x4000000 and 2 <= w <= 64 and 2 <= h <= 64 and row >= w and typ in (2, 4)): return
        cx, cy = struct.unpack('<hh', g.read(m_cur, 4))
        if ptr not in cur3d:
            idx = (np.frombuffer(g.read(ptr, row * h), np.uint8).reshape(h, row)[:, :w] if typ == 2
                   else rle_decode(g.read(ptr, 4096), w, h))
            if not idx.any(): return                     # (la fleche videe des menus)
            cur3d[ptr] = [idx, None]
        idx, hot = cur3d[ptr]
        m = idx != 0
        def place(hx, hy):
            x0, y0 = cx - hx, cy - hy
            if x0 < 0 or y0 < 0 or x0 + w > 320 or y0 + h > 400: return None
            z = scr[y0:y0 + h, x0:x0 + w]
            return (x0, y0) if (z[m] == idx[m]).mean() > 0.9 else None
        at = place(*hot) if hot else None
        if at is None and hot is None:
            for hy in range(h):
                for hx in range(w):
                    at = place(hx, hy)
                    if at: cur3d[ptr][1] = (hx, hy); break
                if at: break
        if at is None: return
        x0, y0 = at
        zone = alpha[y0:y0 + h, x0:x0 + w]
        zone[m & (zone == 255)] = 254
    except Exception:
        return


def hud_loop():
    while True:
        if not send_hud(): time.sleep(0.0005)


if HUD:
    import threading
    threading.Thread(target=hud_loop, daemon=True).start()


# Ecrans du jeu hors de sa 3D (menus, ecran de mort, briefing, video, pause) : le compteur d'images 3D (COPIES) ne
# bouge plus. La fenetre DOSBox est alors capturee (PrintWindow, meme cachee derriere le visualiseur) et envoyee au
# visualiseur en JPEG, qui l'affiche a la place de sa 3D (port 47823) :
#   'MOD' + n (u32) + mode (u8 : 0 = 3D, 1 = ecran du jeu) + cadre de la souris du jeu (i16 l, h) + curseur du
#   visualiseur (u8 : 1 = la fleche du jeu est videe, voir cursor_hide), 5 fois par seconde
#   'SCR' + image (u32) + morceau (u16) + nombre (u16) + [largeur, hauteur de l'ecran, x, y, l, h de la zone (u16) +
#   RGB zlib de la zone] (60 Ko par morceau) : la zone qui a change (le curseur qui bouge : un petit paquet), l'ecran
#   entier chaque seconde ou quand sa taille change, jusqu'a ~40 fois par seconde. Les morceaux d'un gros envoi sont
#   espaces : le tampon de reception de Windows (~64 Ko) debordait et le visualiseur n'avait jamais l'image entiere
#   l'ecran du jeu a sa definition (le cadre de sa souris, 640 x 480 dans les menus), chaque pixel repris au centre
#   de son bloc dans la fenetre DOSBox agrandie ; le visualiseur l'agrandit net
#   'MIS' + n (u32) + nom de la mission (MISSnn.RES), au retour dans la 3D : le visualiseur charge la nouvelle
def menu_loop():
    import ctypes, ctypes.wintypes as wt
    u32, g32 = ctypes.windll.user32, ctypes.windll.gdi32
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except OSError:
        pass
    hwnd = tnre.dosbox_window()

    class BIH(ctypes.Structure):
        _fields_ = [('biSize', wt.DWORD), ('biWidth', wt.LONG), ('biHeight', wt.LONG), ('biPlanes', wt.WORD),
                    ('biBitCount', wt.WORD), ('biCompression', wt.DWORD), ('biSizeImage', wt.DWORD), ('a', wt.LONG),
                    ('b', wt.LONG), ('c', wt.DWORD), ('d', wt.DWORD)]

    import numpy as np

    def grab():
        r = wt.RECT(); u32.GetClientRect(hwnd, ctypes.byref(r)); w, h = r.right, r.bottom
        if w < 16 or h < 16: return None
        hdc = u32.GetDC(hwnd); mdc = g32.CreateCompatibleDC(hdc); bmp = g32.CreateCompatibleBitmap(hdc, w, h)
        g32.SelectObject(mdc, bmp); u32.PrintWindow(hwnd, mdc, 3)
        bi = BIH(ctypes.sizeof(BIH), w, -h, 1, 32, 0, 0, 0, 0, 0, 0); buf = ctypes.create_string_buffer(w * h * 4)
        g32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bi), 0)
        g32.DeleteObject(bmp); g32.DeleteDC(mdc); u32.ReleaseDC(hwnd, hdc)
        return np.frombuffer(buf, np.uint8).reshape(h, w, 4)[:, :, 2::-1]

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    last_c, last_t, mode, n, img_n, prev, sent_t, mod_t = d32(COPIES), time.time(), 0, 0, 0, None, 0.0, 0.0
    fw, fh = 640, 480
    global menu_beat
    while True:
        menu_beat = time.time()
        try:
            last_c, last_t, mode, n, img_n, prev, sent_t, mod_t, fw, fh = menu_step(
                grab, tx, last_c, last_t, mode, n, img_n, prev, sent_t, mod_t, fw, fh)
        except Exception as ex:                   # une capture ratee (changement de mode video...) : on continue
            print('menus :', repr(ex), file=sys.stderr, flush=True); time.sleep(0.2)


def menu_step(grab, tx, last_c, last_t, mode, n, img_n, prev, sent_t, mod_t, fw, fh):
    import collections, os
    import numpy as np
    if True:
        c = d32(COPIES); now = time.time()
        if c != last_c: last_c, last_t = c, now
        # un ecran du jeu : sa 3D arretee, ou sa souris dans un cadre de menu (640 x 480 ; la 3D de TN+ tourne encore
        # au debut de certains ecrans, comme la base : leur image passait alors par le HUD, assombrie)
        fw, fh = struct.unpack('<hh', g.read(m_frame, 4)) if PLAY else (0, 0)   # sans --play : la 3D arretee seulement
        menu = now - last_t > 0.5 or fw >= 640
        if mode == 0 and menu: mode = 1
        elif mode == 1 and not menu and now - last_t < 0.1:
            mode = 0
            if PLAY: cursor_restore()                  # la fleche du jeu, de retour pour la 3D
            menu_step.mis_t = 0.0
        if os.environ.get('TN_DEBUG') and mode != getattr(menu_step, 'dbg', None):
            menu_step.dbg = mode
            print('menus : mode %d (3D arretee %.1f s, cadre %d x %d)' % (mode, now - last_t, fw, fh), file=sys.stderr, flush=True)
        if now - mod_t > 0.2:
            tx.sendto(b'MOD' + struct.pack('<IBhhB', n, mode, fw, fh, 1 if (PLAY and curseur['own']) else 0),
                      ('127.0.0.1', 47823)); n += 1; mod_t = now
        # cinematique en cours : le nom du dernier fichier ouvert par DOS (zone de DOS, vers 0x2B4E) est son .SMK
        # pendant qu'elle joue ; le visualiseur passe alors sa version HD (movies_hd\, faite chez le joueur) s'il l'a
        if now - getattr(menu_step, 'mov_t', 0.0) > 0.2:
            menu_step.mov_t = now
            mm = re.search(rb'([A-Z0-9_]{1,8})\.SMK\x00', g.read(0x2A00, 0x200) or b'') if mode == 1 else None
            nom = mm.group(1).decode() if mm else ''
            if nom != getattr(menu_step, 'mov', '') or now - getattr(menu_step, 'mov_sent', 0.0) > 1.0:
                menu_step.mov, menu_step.mov_sent = nom, now
                if os.environ.get('TN_DEBUG') and nom != getattr(menu_step, 'mov_dbg', None):
                    menu_step.mov_dbg = nom; print('cinematique : %r' % nom, file=sys.stderr, flush=True)
                tx.sendto(b'MOV' + struct.pack('<I', n) + nom.encode(), ('127.0.0.1', 47823))
        if mode == 0:
            # la mission en cours, redite chaque seconde (le visualiseur ne recharge que si elle change) : un seul
            # envoi au retour dans la 3D pouvait se perdre, ou lire le nom de la mission d'avant
            if now - getattr(menu_step, 'mis_t', 0.0) > 1.0:
                menu_step.mis_t = now
                noms = collections.Counter(m.group().decode().upper() for m in re.finditer(rb'miss\d+\.res', g.read(0x340000, 0x140000), re.I))
                if noms:
                    tx.sendto(b'MIS' + struct.pack('<I', n) + noms.most_common(1)[0][0].encode(), ('127.0.0.1', 47823))
            time.sleep(0.05); return last_c, last_t, mode, n, img_n, None, sent_t, mod_t, fw, fh
        im = grab()
        if im is None:
            time.sleep(0.1); return last_c, last_t, mode, n, img_n, prev, sent_t, mod_t, fw, fh
        H, W = im.shape[:2]
        tw, th = (fw, fh) if fw >= 640 and fh >= 400 else (W // 2, H // 2)   # (en mission en pause : moitie de la fenetre)
        ech = im[((np.arange(th) + 0.5) * H / th).astype(int)][:, ((np.arange(tw) + 0.5) * W / tw).astype(int)]
        if PLAY and (tw, th) == (fw, fh):
            cursor_hide(ech, tx, now)
        x0, y0, x1, y1 = 0, 0, tw, th                     # tout l'ecran
        if prev is not None and prev.shape == ech.shape and now - sent_t < 1.0:
            ch = (ech != prev).any(2)
            if not ch.any():
                x1 = 0
            else:
                ys, xs = np.nonzero(ch.any(1))[0], np.nonzero(ch.any(0))[0]
                x0, y0, x1, y1 = int(xs[0]), int(ys[0]), int(xs[-1]) + 1, int(ys[-1]) + 1
        if x1 > x0:
            zone = np.ascontiguousarray(ech[y0:y1, x0:x1])
            data = struct.pack('<6H', tw, th, x0, y0, x1 - x0, y1 - y0) + zlib.compress(zone.tobytes(), 1)
            parts = [data[k:k + 60000] for k in range(0, len(data), 60000)]
            for k, part in enumerate(parts):
                if k: time.sleep(0.008)
                tx.sendto(b'SCR' + struct.pack('<IHH', img_n, k, len(parts)) + part, ('127.0.0.1', 47823))
            img_n += 1
            if (x0, y0, x1, y1) == (0, 0, tw, th): sent_t = now
            prev = ech.copy()
        time.sleep(max(0.0, 0.012 - (time.time() - now)))
    return last_c, last_t, mode, n, img_n, prev, sent_t, mod_t, fw, fh


# Le curseur des ecrans du jeu (menus, panneau d'options d'une mission) : le jeu le redessine a son rythme et DOSBox
# l'affiche avec ~60 ms de retard, puis la capture. Le visualiseur affiche donc la fleche du jeu lui-meme comme
# curseur de la souris (sans retard), et celle du jeu est rendue invisible : son image (descripteur juste avant la
# position du curseur : pointeur, type, ?, largeur, hauteur, pas), brute (type 2, les menus ; 0 transparent) videe,
# ou compressee (type 4, le panneau d'options : RLE) remplacee par un flux valide tout transparent (des
# zeros la cassaient : le jeu semait des morceaux de fleche). Remise en revenant dans la 3D et a l'arret (et au
# demarrage si un pont arrete net l'a laissee : fichier CUR_FILE). Sa pointe est relevee une fois sur l'image, la
# souris immobile (l'image a alors rattrape) ; ses couleurs suivent la palette du jeu.
#   'CUR' + n (u32) + largeur, hauteur, pointe x, y (i16) + RGBA
CUR_FILE = os.path.join(os.environ.get('TEMP', '.'), 'tn_curseurs.bin')
curseur = {'orig': {}, 'img': {}, 'pos': None, 'still': 0.0, 'cur_t': 0.0, 'vide': set(), 'non': set(), 'own': False,
           'last': None}


def rle_decode(f, w, h):
    import numpy as np
    idx = np.zeros(w * h, np.uint8); i = o = 0; n = w * h
    while o < n and i < len(f):
        c = f[i]; i += 1
        if c == 0:
            cnt, v = f[i], f[i + 1]; i += 2; idx[o:o + cnt] = v; o += cnt
        elif c < 0x80:
            seg = f[i:i + c]; idx[o:o + len(seg)] = list(seg)[:n - o]; i += c; o += c
        elif c > 0x80:
            o += c & 0x7F
        else:
            wv = struct.unpack_from('<H', f, i)[0]; i += 2
            if wv == 0: break
            if wv & 0x8000 == 0: o += wv
            elif wv & 0x4000 == 0:
                k = wv & 0x3FFF; seg = f[i:i + k]; idx[o:o + len(seg)] = list(seg)[:n - o]; i += k; o += k
            else:
                k = wv & 0x3FFF; idx[o:o + k] = f[i]; i += 1; o += k
    return idx[:n].reshape(h, w)


def rle_vide(n):
    out = b''
    while n > 0:
        k = min(n, 127); out += bytes([0x80 | k]); n -= k
    return out + b'\x80\x00\x00'


def cursor_hide(ech, tx, now):
    import numpy as np
    st = curseur
    st['own'] = False
    ptr, typ, _, w, h, row = struct.unpack('<IHHHHH', g.read(m_cur - 0x18, 14))
    if not (0x400000 <= ptr < 0x4000000 and 4 <= w <= 64 and 4 <= h <= 64 and row >= w and typ in (2, 4))             or ptr in st['non']:
        return
    if ptr in st['orig']:
        orig, vide = st['orig'][ptr]
        cur = g.read(ptr, len(vide))
        if ptr in st['vide'] and cur != vide:            # le jeu l'a remise : on la lui laisse
            st['non'].add(ptr); st['vide'].discard(ptr)
            print('menus : le jeu remet sa fleche, laissee', file=sys.stderr, flush=True)
            return
    else:
        bm = g.read(ptr, row * h)
        brute = typ == 2                                 # type de l'image : 2 brute, 4 compressee (RLE)
        if not any(bm): return
        vide = bytes(row * h) if brute else rle_vide(w * h)
        orig = g.read(ptr, len(vide))
        idx = np.frombuffer(bm, np.uint8).reshape(h, row)[:, :w] if brute else rle_decode(g.read(ptr, 4096), w, h)
        st['orig'][ptr] = (orig, vide); st['idx_' + str(ptr)] = idx
        with open(CUR_FILE, 'ab') as f:
            f.write(struct.pack('<IH', ptr, len(vide)) + orig + vide)
    orig, vide = st['orig'][ptr]
    pos = g.read(m_cur, 4)
    if pos != st['pos']: st['pos'], st['still'] = pos, now
    idx = st['idx_' + str(ptr)]
    pal = np.frombuffer(g.read(PAL, 768), np.uint8).reshape(256, 3)
    if ptr not in st['img']:
        if ptr in st['vide'] or now - st['still'] < 0.25: return    # la fleche visible et immobile : on la releve
        if pal[idx[idx != 0]].max() < 40: return     # ecran en fondu (palette au noir) : pointe pas lisible
        cx, cy = struct.unpack('<hh', pos)
        H, W = ech.shape[:2]
        best = None
        for hy in range(0, 8):
            for hx in range(0, 8):
                x0, y0 = cx - hx, cy - hy
                if x0 < 0 or y0 < 0 or x0 + w > W or y0 + h > H: continue
                zone = ech[y0:y0 + h, x0:x0 + w]
                sc = 0
                for v in np.unique(idx[idx != 0]):
                    cols = zone[idx == v].reshape(-1, 3)
                    u, c = np.unique(cols, axis=0, return_counts=True)
                    sc += c.max()
                if best is None or sc > best[0]: best = (sc, hx, hy)
        if best is None or best[0] < 0.9 * (idx != 0).sum(): return
        _, hx, hy = best
        zone = ech[cy - hy:cy - hy + h, cx - hx:cx - hx + w]
        st['img'][ptr] = (hx, hy)
        print('menus : curseur releve (%d x %d, pointe %d, %d)' % (w, h, hx, hy), file=sys.stderr, flush=True)
        if os.environ.get('TN_DEBUG'):
            from PIL import Image
            Image.fromarray(pal[idx]).resize((w * 8, h * 8), 0).save(os.path.join(os.environ.get('TEMP', '.'), 'tn_curseur_%x.png' % ptr))
    if ptr not in st['vide']:
        g.write(ptr, vide)                                     # la fleche du jeu : invisible
        st['vide'].add(ptr)
    st['own'] = True
    # ses couleurs : la palette du jeu du moment (relevees une fois sur l'image, elles restaient celles de l'ecran
    # du releve : une fleche relevee pendant un fondu restait noire)
    r = np.zeros((h, w, 4), np.uint8)
    r[..., :3] = pal[idx]; r[..., 3] = np.where(idx != 0, 255, 0)
    if now - st['cur_t'] > 1.0 or st['last'] != (ptr, r.tobytes()):
        st['cur_t'], st['last'] = now, (ptr, r.tobytes())
        hot = st['img'][ptr]
        tx.sendto(b'CUR' + struct.pack('<I4h', 0, r.shape[1], r.shape[0], *hot) + r.tobytes(), ('127.0.0.1', 47823))


def cursor_restore():
    for ptr in list(curseur['vide']):
        orig, vide = curseur['orig'][ptr]
        if g.read(ptr, len(vide)) == vide:
            g.write(ptr, orig)
    curseur['vide'].clear(); curseur['non'].clear(); curseur['own'] = False


def cursor_repare():
    """au demarrage : les fleches laissees invisibles par un pont arrete net, remises depuis les copies gardees
    (CUR_FILE), puis depuis les fichiers du jeu : une image de curseur de RESGAME / RESCUSTM (en-tete de 0x1c octets,
    puis ses pixels) retrouvee en memoire avec des pixels vides est remise, si c'est la seule de son en-tete a y manquer"""
    entete = re.compile(b'\x00\x00\x00\x00[\x02\x04]\x00\x01\x00', re.S)
    if os.path.exists(CUR_FILE):
        f = open(CUR_FILE, 'rb').read(); i = 0
        while i + 6 <= len(f):
            ptr, n = struct.unpack_from('<IH', f, i); orig, vide = f[i + 6:i + 6 + n], f[i + 6 + n:i + 6 + 2 * n]
            i += 6 + 2 * n
            # une fleche videe de ce jeu-ci : son en-tete juste avant (un autre jeu lance depuis peut avoir des zeros
            # a cette adresse, qu'il ne faut pas remplir)
            if len(vide) == n and entete.match(g.read(ptr - 0x1c, 0x1c) or b'') and g.read(ptr, n) == vide:
                g.write(ptr, orig); print('menus : fleche du jeu remise (%#x)' % ptr)
        os.remove(CUR_FILE)                          # (les fleches videes ensuite y seront notees a nouveau)
    dossier = jeu_data()
    if not dossier: return
    cand = {}
    for nom in ('RESGAME.RES', 'RESCUSTM.RES'):
        fn = os.path.join(dossier, nom)
        if not os.path.exists(fn): continue
        b = open(fn, 'rb').read()
        for m in entete.finditer(b):
            k = m.start(); typ = b[k + 4]; w, h, row = struct.unpack_from('<HHH', b, k + 8)
            if not (4 <= w <= 64 and 4 <= h <= 64 and row >= w): continue
            px = b[k + 0x1c:k + 0x1c + row * h] if typ == 2 else b[k + 0x1c:k + 0x1c + 4096]
            if typ == 4:                             # le flux compresse : jusqu'a sa fin (0x80 0 0)
                e = px.find(b'\x80\x00\x00'); px = px[:e + 3] if e >= 0 else b''
            if px: cand.setdefault(b[k:k + 0x1c], set()).add(px)
    for hdr, imgs in cand.items():
        n = max(len(px) for px in imgs)
        intactes, vides = set(), []
        for st in range(0x400000, 0x4000000, 0x100000):
            blk = g.read(st, 0x100000 + 0x1c + n)
            if not blk: continue
            k = blk.find(hdr)
            while 0 <= k < 0x100000:
                for px in imgs:
                    if blk[k + 0x1c:k + 0x1c + len(px)] == px: intactes.add(px); break
                else:
                    cur = blk[k + 0x1c:k + 0x1c + n]
                    if not any(cur) or (cur[0] >= 0x80 and b'\x80\x00\x00' in cur[:12]): vides.append(st + k + 0x1c)
                k = blk.find(hdr, k + 1)
        # une image videe : celle des fichiers qui manque en memoire (les autres de meme en-tete y sont intactes)
        reste = imgs - intactes
        if len(reste) == 1 and len(vides) == 1:
            g.write(vides[0], next(iter(reste)))
            print('menus : fleche du jeu remise depuis les fichiers (%#x)' % vides[0])


def jeu_data():
    """dossier TNOVA/DATA du jeu, d'apres l'executable de DOSBox (son dossier ou un parent)"""
    import ctypes
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x1000, False, g.pid)
    buf = ctypes.create_unicode_buffer(1024); n = ctypes.c_ulong(1024)
    ok = k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)); k32.CloseHandle(h)
    if not ok: return None
    d = os.path.dirname(buf.value)
    for _ in range(3):
        if os.path.isdir(os.path.join(d, 'TNOVA', 'DATA')): return os.path.join(d, 'TNOVA', 'DATA')
        d = os.path.dirname(d)
    return None


# le visualiseur au premier plan : lance depuis TNPlus pendant que DOSBox a le focus, Windows le laissait derriere
# (DOSBox en plein ecran gardait alors la souris, cachee) ; ramene devant chaque fois que DOSBox reprend le focus
# (changement de mode video...), pas quand le joueur passe a une autre application
devant_t, devant_hw = 0.0, None


def devant():
    global devant_t, devant_hw
    import ctypes, ctypes.wintypes as wt
    u = tnre.u32
    devant_t = time.time()
    if devant_hw is None or not u.IsWindowVisible(devant_hw):
        trouve = []

        @ctypes.WINFUNCTYPE(wt.BOOL, ctypes.c_void_p, ctypes.c_void_p)
        def cb(h, _):
            q = wt.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(q))
            if q.value == viewer.pid and u.IsWindowVisible(h): trouve.append(h)
            return True
        u.EnumWindows(cb, 0)
        devant_hw = trouve[0] if trouve else None
    fg = u.GetForegroundWindow()
    if devant_hw is None or fg == devant_hw: return
    q = wt.DWORD(); t_fg = u.GetWindowThreadProcessId(fg, ctypes.byref(q)) if fg else 0
    if fg and q.value != g.pid: return                   # une autre application : on la laisse
    t_moi = tnre.k32.GetCurrentThreadId()
    if t_fg: u.AttachThreadInput(t_moi, t_fg, True)
    u.BringWindowToTop(devant_hw); u.SetForegroundWindow(devant_hw)
    if t_fg: u.AttachThreadInput(t_moi, t_fg, False)


import atexit
guest = None
if '--guest' in sys.argv or '--guest-remote' in sys.argv:   # coop (TN+ Coop build): a teammate played by a second player
    import coop_guest                           # (--guest-remote: online, through the host window's Steam link)
    guest = coop_guest.Guest(g, A_MASTER, A_PID, NENT, EYE, SENS_X, fov_now, s, remote='--guest-remote' in sys.argv,
                             view_hz=arg('--view-hz', 20.0))   # online: views a second to the guest
atexit.register(cursor_restore)
if viewer is not None:                    # le jeu ferme (lecture ratee) ou le pont arrete : le visualiseur aussi
    atexit.register(lambda: viewer.poll() is None and viewer.terminate())
if PLAY:
    cursor_repare()
menu_beat = time.time()
if HUD:
    threading.Thread(target=menu_loop, daemon=True).start()
u16 = lambda a: struct.unpack('<H', g.read(a, 2))[0]
s16 = lambda a: struct.unpack('<h', g.read(a, 2))[0]
i32 = lambda a: struct.unpack('<i', g.read(a, 4))[0]
n = 0
while True:
    e = A_MASTER + u16(A_PID + 2) * 0x25
    x, y, z = i32(e + 0x0F) / 65536, i32(e + 0x13) / 65536, i32(e + 0x17) / 65536
    # cap de la vue principale = cap du joueur + tete, comme le jeu le calcule : la variable cap camera sert aussi aux
    # vues laterales (triple camera, cockpit) et la lire au mauvais moment faisait sauter la vue de 52 deg
    head = ((u16(e + 0x1B) + u16(A_HEADYAW)) & 0xffff) / 65536 * 2 * math.pi
    pitch = -s16(A_CAMPITCH) / 65536 * 2 * math.pi    # le jeu : positif = vers le bas
    # entites du jeu (table de 0x25 octets) : classes 0 a 4 (decor, unites, vehicules, sondes, batiments), 5 = tirs
    # et 6 = eclats d'impact (ephemeres : envoyes seulement actifs)
    tab = g.read(A_MASTER, 0x25 * NENT)
    body = []
    if time.time() - corps_t > 0.5:
        corps_t = time.time()
        raw = g.read(CORPS, 200 * 0x14E)
        corps = [(n, *(v / 65536 for v in struct.unpack_from('<ii', raw, n * 0x14E))) for n in range(200)]
    vivants = {struct.unpack_from('<H', tab, 0x25 * i + 3)[0] for i in range(NENT) if tab[0x25 * i] and tab[0x25 * i + 1] == 1}
    for i in range(NENT):
        o = 0x25 * i
        if tab[o + 1] > 6 or (tab[o + 1] >= 5 and tab[o] == 0): continue
        ex, ey, ez = struct.unpack_from('<iii', tab, o + 0x0F)
        if ex == 0 and ey == 0: continue
        eh = struct.unpack_from('<H', tab, o + 0x1B)[0] / 65536 * 2 * math.pi
        if tab[o + 1] == 6 and tab[o + 2] in (28, 29):   # poussiere : le cap porte le champ que le jeu retire au
            eh = float(struct.unpack_from('<H', tab, o + 7)[0])   # hasard (il disperse ses points autour d'elle)
        if tab[o + 1] == 6 and tab[o + 2] == 33:     # morceau d'armure : le cap porte l'armure du soldat mort
            eh = float(armure_debris(ex / 65536, ey / 65536, vivants))
        body.append(struct.pack('<4i4f', i, tab[o + 1], tab[o + 2], 1 if tab[o] else 0, ex / 65536, ey / 65536, ez / 65536, eh))
    pid = u16(A_PID + 2)
    # animation des soldats : le jeu calcule a chaque image les 16 articulations de chaque armure affichee (fiche
    # soldat n = mot a +3 de l'entree, articulations a +0x1AF) ; envoyees dans le repere du soldat (droite, haut,
    # avant ; sol sous les pieds), comme les poses figees du visualiseur (poses.py), apres la hauteur de ses pieds
    joints = []
    for i in range(NENT):
        o = 0x25 * i
        if not tab[o] or tab[o + 1] != 1: continue      # (le joueur aussi : il se voit dans les vues annexes)
        nf = struct.unpack_from('<H', tab, o + 3)[0]
        if nf > 200: continue
        jr = g.read(SOLDATS + nf * 0x582 + 0x1AF, 192)
        j = [struct.unpack_from('<3i', jr, 12 * k) for k in range(16)]
        x0, y0 = struct.unpack_from('<ii', tab, o + 0x0F)
        mech = tab[o + 2] == 9                     # le mech (type 9, squelette 886) : 10 articulations, grande foulee
        used = j[:10] if mech else j
        if any(math.hypot(v[0] - x0, v[1] - y0) > (0.9 if mech else 0.45) * 65536 for v in used) or any(v == (0, 0, 0) for v in used):
            continue                          # pas affiche : articulations pas a jour (une armure tient dans 0,25 ;
                                              # au-dela Godot etire le maillage en gros bloc noir)
        cap = struct.unpack_from('<H', tab, o + 0x1B)[0] / 65536 * 2 * math.pi
        av, dr = (math.cos(cap), math.sin(cap)), (-math.sin(cap), math.cos(cap))
        q = [((v[0] - x0) / 65536, (v[1] - y0) / 65536, v[2] / 65536) for v in j]
        sg = 1 if q[9][2] > q[8][2] else -1
        sol = min(w[2] * sg for w in q[:4])
        joints.append(struct.pack('<if48f', i, sol * sg, *[c for w in q for c in (w[0] * dr[0] + w[1] * dr[1], w[2] * sg - sol, w[0] * av[0] + w[1] * av[1])]))
    for _ in range(24):                   # vues annexes : leur point de vue, pris pendant leur dessin
        vp = g.read(VUEPT, 0x68)
        vx, vy, vz = (v / 65536 for v in struct.unpack_from('<3i', vp, 0))
        vi = struct.unpack_from('<H', vp, 0x5A)[0]           # l'entite de la vue (+0x5A)
        # celle du joueur : la camera de cible du panneau du bas a gauche (mode 0x15 : bouton viseur, une cible
        # verrouillee ; du joueur vers la cible, zoom = distance bornee a 1-16), sinon rien (tester la position la
        # confondait avec une vue annexe quand le joueur avancait, Z ; et ecartait une sonde posee a cote de lui)
        cible = vi == pid
        if cible and g.read(MODES, 1)[0] != 0x15: continue
        if cible and abs(vz - (z + d32(OEIL) / 65536 + 0.1875)) > 0.03: continue   # (une autre ecriture du joueur, a son
                                              # cap et 0,4 au-dessus de lui, se glisse entre : pas la camera de cible)
        if not 0 <= vi < NENT or not tab[0x25 * vi] or tab[0x25 * vi + 1] not in (1, 2, 3): continue
        # le jeu y ecrit lui-meme cap (+0xC) et tangage (+0x16, positif = vers le bas) de la vue (routine 0x275260 de
        # l'exe anglais : cap de l'unite + reglage du panneau + visee), hauteur = z de l'unite + [0x38FB1C] + 0,1875
        cap_v = struct.unpack_from('<H', vp, 0xC)[0] / 65536 * 2 * math.pi
        tang_v = -struct.unpack_from('<h', vp, 0x16)[0] / 65536 * 2 * math.pi
        vz += EYE - (d32(OEIL) / 65536 + 0.1875)  # meme oeil que la vue principale (EYE, ajuste sur le jeu)
        panneau = 2 if cible else (3 if tab[0x25 * vi + 1] == 3 else 1)
        zoom = d32(CAMS + (0xBA * 2 if panneau == 3 else 0)) / 65536
        if not 0.2 < zoom < 20: zoom = 1.0
        # garde l'ecart a l'unite (le point de vue n'est capte qu'au hasard du dessin : relu tel quel, la vue avancait
        # par saccades) ; la position est reprise a chaque tour dans la table, le cap de l'unite + l'ecart (la cible :
        # son cap tel quel, il vise la cible et non l'avant du joueur)
        ex_, ey_, ez_ = (v / 65536 for v in struct.unpack_from('<3i', tab, 0x25 * vi + 0x0F))
        ecap = struct.unpack_from('<H', tab, 0x25 * vi + 0x1B)[0] / 65536 * 2 * math.pi
        vues[panneau] = (time.time(), vi, vx - ex_, vy - ey_, vz - ez_, cap_v if cible else cap_v - ecap, tang_v, zoom)
    sv = []
    for k, v in vues.items():
        if time.time() - v[0] > 0.4 or not tab[0x25 * v[1]]: continue
        ex_, ey_, ez_ = (c / 65536 for c in struct.unpack_from('<3i', tab, 0x25 * v[1] + 0x0F))
        ecap = struct.unpack_from('<H', tab, 0x25 * v[1] + 0x1B)[0] / 65536 * 2 * math.pi
        sv.append((k, (v[0], v[1], ex_ + v[2], ey_ + v[3], ez_ + v[4], v[5] if k == 2 else ecap + v[5], v[6], v[7])))
    cd = cadres() if sv else []
    if cd:                                    # VUE : le panneau du bas le plus a gauche ; la sonde : le plus a droite
        s.sendto(b'SUBV' + bytes([len(sv)]) + b''.join(struct.pack('<Bi6f4h', k, v[1], *v[2:], *(cd[-1] if k == 3 else cd[0]))
                 for k, v in sv), ('127.0.0.1', 47821))
    elif not sv:
        s.sendto(b'SUBV' + bytes([0]), ('127.0.0.1', 47821))
    cam = (x, y, z + EYE, head, pitch)
    if CAM: cam = CAM                         # --cam x,y,z,cap_deg,tangage_deg : camera d'observation fixe (tests)
    s.sendto(struct.pack('<6f2i', *cam, fov_now(), len(body), pid) + b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints),
             ('127.0.0.1', 47821))
    if guest: guest.step(body, joints)
    if '--once' in sys.argv or n % int(HZ * 2) == 0:
        print('x %.2f y %.2f z %.2f cap %.1f deg tangage %.1f deg' % (x, y, z, math.degrees(head), math.degrees(pitch)))
        if '--once' in sys.argv: break
    if HUD and time.time() - menu_beat > 3:     # fil des menus fige (capture bloquee) : un neuf prend la suite
        menu_beat = time.time()
        print('menus : fil relance', file=sys.stderr, flush=True)
        threading.Thread(target=menu_loop, daemon=True).start()
    if PLAY:
        handle_input()
    if time.time() - nuages_t > 0.1:
        nuages_t = time.time()
        s.sendto(b'SKYO' + struct.pack('<2f', *(v / 65536 for v in struct.unpack('<2i', g.read(NUAGES, 8)))), ('127.0.0.1', 47821))
        s.sendto(b'IRVW' + bytes([1 if g.read(INFRA, 1)[0] == 1 else 0]), ('127.0.0.1', 47821))
    if time.time() - brule_t > 0.5:           # sommets brules : lus 2 fois par seconde, envoyes s'ils changent (et toutes les 2 s)
        brule_t = time.time()
        carte = None
        for a in SOL_PTRS:
            pc = struct.unpack('<I', g.read(a, 4))[0]
            if 0x400000 <= pc < 0x4000000 and 0 <= x < 512 and 0 <= y < 512:
                h = struct.unpack('<h', g.read(pc + 3 * (int(y) * 513 + int(x)) + 1, 2))[0] / 384
                if abs(h - z) < 1.5:
                    carte = pc
                    break
        if carte is not None:
            tuiles = g.read(carte, 513 * 513 * 3)[0::3]
            br = [m.start() for m in BRULE.finditer(tuiles)][:15000]
            if br != brule_prev or brule_t - brule_sent > 2.0:
                s.sendto(b'SCOR' + struct.pack('<I%dI' % len(br), len(br), *br), ('127.0.0.1', 47821))
                brule_prev, brule_sent = br, brule_t
    if time.time() - veg_t > 0.25:            # vegetation : lue 4 fois par seconde, envoyee si elle change (et chaque seconde)
        veg_t = time.time()
        vg = g.read(VEG, 128 * 128)
        if vg != veg_prev or veg_t - veg_sent > 1.0:
            s.sendto(b'VEGM' + vg, ('127.0.0.1', 47821))
            veg_prev, veg_sent = vg, veg_t
    n += 1
    if viewer is not None and viewer.poll() is not None:
        break
    if viewer is not None and time.time() - devant_t > 0.5:
        devant()
    if PLAY:
        select.select([rx], [], [], 1 / HZ)   # clavier / souris traites des leur arrivee
    else:
        time.sleep(1 / HZ)
