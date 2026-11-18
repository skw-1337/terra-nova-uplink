"""Builds release.json, the launcher's single source of truth (docs/release-manifest.md), from a short spec.

    python tools/release/make_manifest.py SPEC.json -o release.json [--uplink-repo DIR] [--tnplus-repo DIR]
                                          [--previous release.json] [--verify-remote] [--stage DIR]

SPEC.json names, per channel, the version and git revisions (branches, tags or commits); everything else is computed
here from the commits themselves: the exact commit, the launcher's version (launcher/TerraNovaUplink.cs), the SHA-256
of every file of Uplink's tree and of each tree as a whole (what the launcher checks after unpacking GitHub's archive),
and the consistency checks (the version is the launcher's and project.godot's, min_launcher <= launcher...).
--verify-remote downloads GitHub's own archive of each commit and checks that it gives the same SHA-256 (run it after
the commits are pushed, before release.json is). Nothing is pushed or published by this script.
"""
import argparse, hashlib, io, json, os, re, subprocess, sys, urllib.request, zipfile

UPLINK_REPO, TNPLUS_REPO = 'skw-1337/terra-nova-uplink', 'skw-1337/terra-nova-plus'
RELEASE_RAW = 'https://raw.githubusercontent.com/%s/release/' % UPLINK_REPO
PICTURES_MAX, CAPTION_MAX, PICTURE_BYTES_MAX = 6, 110, 400 * 1024
SEMVER = re.compile(r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$')


def semver(v):
    m = SEMVER.match(v or '')
    if not m:
        raise SystemExit('not a version: %r' % v)
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0), (m.group(4).split('.') if m.group(4) else [])


def vcmp(a, b):
    x, y = semver(a), semver(b)
    if x[:3] != y[:3]:
        return (x[:3] > y[:3]) - (x[:3] < y[:3])
    if not x[3] or not y[3]:
        return (len(y[3]) > 0) - (len(x[3]) > 0) if (x[3] or y[3]) else 0
    for p, q in zip(x[3], y[3]):
        if p == q:
            continue
        if p.isdigit() and q.isdigit():
            return (int(p) > int(q)) - (int(p) < int(q))
        if p.isdigit() or q.isdigit():
            return -1 if p.isdigit() else 1
        return (p > q) - (p < q)
    return (len(x[3]) > len(y[3])) - (len(x[3]) < len(y[3]))


def skip(path):  # what Godot and Python make by themselves, and the launcher's own list: as the launcher (TreeSkip)
    return path.startswith('.godot/') or path.startswith('__pycache__/') or '/__pycache__/' in path or path == '.release-files'


def tree_of_zip(data):
    """{path: sha256} of an archive as GitHub makes it (one top folder), and the tree's SHA-256 (as TreeDigest)"""
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if not n.endswith('/')]
        tops = {n.split('/', 1)[0] for n in z.namelist()}
        strip = len(tops) == 1 and all('/' in n for n in names)
        for n in names:
            p = n.split('/', 1)[1] if strip else n
            if not skip(p):
                files[p] = hashlib.sha256(z.read(n)).hexdigest()
    return files, digest(files)


def digest(files):
    keys = sorted(files)          # (code points: the launcher's ordinal order on UTF-16, the same for the paths a tree holds)
    return hashlib.sha256(''.join('%s %s\n' % (files[k], k) for k in keys).encode('utf-8')).hexdigest()


def jpeg_size(data):
    """(width, height) of a baseline or progressive JPEG, None if it is not one"""
    if data[:2] != bytes((0xFF, 0xD8)):
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            return None
        m = data[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        n = int.from_bytes(data[i + 2:i + 4], 'big')
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            return int.from_bytes(data[i + 7:i + 9], 'big'), int.from_bytes(data[i + 5:i + 7], 'big')
        i += 2 + n
    return None


def check_picture(path):
    """an invitation picture as the launcher shows it best: a light 16:9 JPEG, 960 pixels wide or more"""
    if not os.path.exists(path):
        return ['missing']
    data = open(path, 'rb').read()
    wh = jpeg_size(data)
    out = []
    if not wh:
        return ['not a JPEG']
    w, h = wh
    if abs(w * 9 - h * 16) > w * 9 // 100:
        out.append('%dx%d is not 16:9 (the carousel shows 16:9)' % (w, h))
    if w < 960:
        out.append('%d pixels wide, under 960 (blurred at 150 %%)' % w)
    if len(data) > PICTURE_BYTES_MAX:
        out.append('%d KB, over %d KB' % (len(data) // 1024, PICTURE_BYTES_MAX // 1024))
    return out


def check_changelog(cl):
    """sections with a name ("" = a plain note line at the end) and at least one non-empty item each"""
    out = []
    if not isinstance(cl, list):
        return ['changelog is not a list of sections']
    for k, sec in enumerate(cl):
        if not isinstance(sec, dict) or not isinstance(sec.get('section'), str):
            out.append('changelog section %d has no "section"' % k)
            continue
        items = sec.get('items')
        if not isinstance(items, list) or not items or not all(isinstance(t, str) and t.strip() for t in items):
            out.append('changelog section %r: "items" must be non-empty texts' % sec['section'])
    return out


def git(repo, *a):
    return subprocess.run(['git', '-C', repo, '-c', 'core.autocrlf=false', '-c', 'core.eol=lf'] + list(a),
                          check=True, capture_output=True).stdout


def part(repo_dir, rev, with_files):
    sha = git(repo_dir, 'rev-parse', rev + '^{commit}').decode().strip()
    files, tree = tree_of_zip(git(repo_dir, 'archive', '--format=zip', '--prefix=top/', sha))
    p = {'ref': sha, 'tree_sha256': tree}
    if with_files:
        p['files'] = dict(sorted(files.items()))
    return p, files


def show(repo_dir, sha, path):
    try:
        return git(repo_dir, 'show', '%s:%s' % (sha, path)).decode('utf-8-sig')
    except subprocess.CalledProcessError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('spec')
    ap.add_argument('-o', '--out', required=True)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--uplink-repo', default=os.path.normpath(os.path.join(here, '..', '..')))
    ap.add_argument('--tnplus-repo', default=os.path.normpath(os.path.join(here, '..', '..', '..', 'TerraNovaPlus')))
    ap.add_argument('--previous', help='the release.json published now: its deps are kept when the spec has none')
    ap.add_argument('--verify-remote', action='store_true')
    ap.add_argument('--stage', metavar='DIR', help='also lay out the release branch there: release.json and the pictures at their paths')
    a = ap.parse_args()
    spec = json.load(open(a.spec, encoding='utf-8'))
    out = {'schema': 1, 'repo': UPLINK_REPO, 'channels': {}}
    problems, pictures = [], []
    for name in ('stable', 'beta'):
        c = spec.get('channels', {}).get(name)
        if not c:
            continue
        ver = c['version']
        semver(ver)
        up, files = part(a.uplink_repo, c['uplink'], True)
        src = show(a.uplink_repo, up['ref'], 'launcher/TerraNovaUplink.cs') or ''
        m = re.search(r'const string VERSION = "([^"]+)"', src)
        launcher = m.group(1) if m else None
        if launcher != ver:
            problems.append('%s: launcher/TerraNovaUplink.cs at %s says %s, the channel %s' % (name, up['ref'][:7], launcher, ver))
        pg = show(a.uplink_repo, up['ref'], 'project.godot') or ''
        pm = re.search(r'(?m)^config/version="([^"]+)"', pg)
        if pm and pm.group(1) != ver:
            problems.append('%s: project.godot says %s, the channel %s' % (name, pm.group(1), ver))
        if src and show(a.uplink_repo, up['ref'], 'launcher/TerraNovaCoop.cs') != src:
            problems.append('%s: launcher/TerraNovaCoop.cs is not a copy of TerraNovaUplink.cs' % name)
        ch = {'version': ver, 'launcher': launcher or '?', 'min_launcher': c.get('min_launcher', launcher or ver), 'uplink': up}
        if vcmp(ch['min_launcher'], ch['launcher']) > 0:
            problems.append('%s: min_launcher %s above its launcher %s' % (name, ch['min_launcher'], ch['launcher']))
        for k in ('tnplus', 'tnplus_coop'):
            p, _ = part(a.tnplus_repo, c[k], False)
            p['version'] = c.get(k + '_version', '')
            ch[k] = p
        if c.get('changelog'):
            ch['changelog'] = c['changelog']
            problems += ['%s: %s' % (name, m) for m in check_changelog(c['changelog'])]
        if c.get('invitation'):
            inv = dict(c['invitation'])
            imgs = []
            for im in inv.get('images', []):
                im = dict(im)
                if 'file' in im:                      # a picture on the release branch: its address and SHA-256 from the file
                    rel = im.pop('file').replace(os.sep, '/')
                    path = os.path.join(os.path.dirname(os.path.abspath(a.spec)), rel)
                    im.setdefault('url', RELEASE_RAW + rel)
                    if im['url'] != RELEASE_RAW + rel:
                        problems.append('%s: picture %s: its url must be %s' % (name, rel, RELEASE_RAW + rel))
                    problems += ['%s: picture %s: %s' % (name, rel, m) for m in check_picture(path)]
                    im['sha256'] = hashlib.sha256(open(path, 'rb').read()).hexdigest() if os.path.exists(path) else ''
                    pictures.append((rel, path))
                if not (im.get('caption') or '').strip():
                    problems.append('%s: picture %s has no caption' % (name, im.get('url')))
                elif len(im['caption']) > CAPTION_MAX:
                    problems.append('%s: caption longer than %d characters (two lines under the picture): %r' % (name, CAPTION_MAX, im['caption']))
                imgs.append({'url': im['url'], 'sha256': im['sha256'], 'caption': im['caption']})
            if len(imgs) > PICTURES_MAX:
                problems.append('%s: %d pictures, the launcher shows %d at most' % (name, len(imgs), PICTURES_MAX))
            if imgs:
                inv['images'] = imgs
            ch['invitation'] = inv
        out['channels'][name] = ch
    if 'stable' not in out['channels']:
        problems.append('no stable channel')
    b, s = out['channels'].get('beta'), out['channels'].get('stable')
    if b and s and vcmp(b['version'], s['version']) <= 0:
        print('note: beta %s is not newer than stable %s: beta testers follow stable, nobody is invited' % (b['version'], s['version']))
    deps = spec.get('deps')
    if deps is None and a.previous and os.path.exists(a.previous):
        deps = json.load(open(a.previous, encoding='utf-8')).get('deps')
    if deps:
        out['deps'] = deps
    if problems:
        raise SystemExit('release.json NOT written:\n  ' + '\n  '.join(problems))
    if a.verify_remote:
        for name, ch in out['channels'].items():
            for k, repo in (('uplink', UPLINK_REPO), ('tnplus', TNPLUS_REPO), ('tnplus_coop', TNPLUS_REPO)):
                url = 'https://codeload.github.com/%s/zip/%s' % (repo, ch[k]['ref'])
                data = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'make_manifest'}), timeout=120).read()
                got = tree_of_zip(data)[1]
                print('%-6s %-11s %s %s' % (name, k, 'OK  ' if got == ch[k]['tree_sha256'] else 'DIFF', url))
                if got != ch[k]['tree_sha256']:
                    raise SystemExit('GitHub\'s archive differs from the local commit: release.json NOT written')
    with open(a.out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write('\n')
    if a.stage:
        import shutil
        os.makedirs(a.stage, exist_ok=True)
        shutil.copyfile(a.out, os.path.join(a.stage, 'release.json'))
        for rel, path in pictures:
            dst = os.path.join(a.stage, *rel.split('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(path, dst)
        print('release branch laid out in', a.stage, '(release.json + %d pictures)' % len(pictures))
    for name, ch in out['channels'].items():
        print('%-6s %-14s uplink %s  tnplus %s  coop %s  launcher %s (min %s)' % (name, ch['version'], ch['uplink']['ref'][:7],
              ch['tnplus']['ref'][:7], ch['tnplus_coop']['ref'][:7], ch['launcher'], ch['min_launcher']))
    print('written', a.out)


if __name__ == '__main__':
    main()
