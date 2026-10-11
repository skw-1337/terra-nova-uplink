# Cutscenes in HD, made on the player's own machine from their own copy of the game (nothing of the game is
# distributed): each Smacker video of TNOVA\MOVIE is upscaled x4 (Real-ESRGAN, video model) and taken from 15 to
# 60 fps (RIFE), then saved as a silent Ogg Theora (the game still plays the sound) in movies_hd\ next to the
# viewer, where the live mode plays it over the game's own cutscene.
#   python upscale_movies.py [NAME ...]            (default: every video; NAME = OPENERA, SCEN05A...)
#   options: --game DIR (folder holding TNOVA), --esrgan DIR, --rife DIR, --ffmpeg EXE, --fps 60, --height 960
import glob, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'movies_hd')
a = sys.argv[1:]
opt = lambda k, d: a[a.index(k) + 1] if k in a else d
GAME = opt('--game', r'C:\Program Files (x86)\Steam\steamapps\common\Terra Nova Strike Force Centauri')
ESRGAN = opt('--esrgan', r'C:\Tools\realesrgan')
RIFE = opt('--rife', (glob.glob(r'C:\Tools\rife\rife-ncnn-vulkan-*') or [r'C:\Tools\rife'])[0])
FFMPEG = opt('--ffmpeg', r'C:\Tools\ffmpeg\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe')
FPS = int(opt('--fps', '60'))
HEIGHT = int(opt('--height', '960'))
names = [x.upper().replace('.SMK', '') for i, x in enumerate(a) if not x.startswith('--') and (i == 0 or not a[i - 1].startswith('--'))]

movie = os.path.join(GAME, 'TNOVA', 'MOVIE')
todo = names or sorted(os.path.splitext(f)[0].upper() for f in os.listdir(movie) if f.upper().endswith('.SMK'))
os.makedirs(OUT, exist_ok=True)


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise SystemExit('failed: %s\n%s' % (' '.join(cmd[:3]), r.stderr[-800:]))


for name in todo:
    src = os.path.join(movie, name + '.SMK')
    dst = os.path.join(OUT, name + '.ogv')
    if not os.path.exists(src):
        print(name, ': not found'); continue
    if os.path.exists(dst):
        print(name, ': already done'); continue
    tmp = tempfile.mkdtemp(prefix='tnmov_')
    try:
        frames, big, smooth = (os.path.join(tmp, d) for d in ('in', 'x4', 'smooth'))
        for d in (frames, big, smooth): os.makedirs(d)
        run([FFMPEG, '-v', 'error', '-i', src, '-an', os.path.join(frames, 'f_%05d.png')])
        n = len(os.listdir(frames))
        run([os.path.join(ESRGAN, 'realesrgan-ncnn-vulkan.exe'), '-i', frames, '-o', big, '-n', 'realesr-animevideov3', '-s', '4', '-f', 'png'], cwd=ESRGAN)
        run([os.path.join(RIFE, 'rife-ncnn-vulkan.exe'), '-i', big, '-o', smooth, '-m', 'rife-v4.6', '-n', str(n * FPS // 15), '-f', 'f_%05d.png'], cwd=RIFE)
        run([FFMPEG, '-v', 'error', '-y', '-framerate', str(FPS), '-i', os.path.join(smooth, 'f_%05d.png'),
             '-vf', 'scale=-2:%d:flags=lanczos' % HEIGHT, '-c:v', 'libtheora', '-q:v', '8', '-an', dst])
        print('%s : %d frames -> %s' % (name, n, dst))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
