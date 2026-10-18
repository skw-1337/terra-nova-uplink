"""Builds TerraNovaCoop_test.zip: the Uplink coop files, the TN+ Coop exe and a short README_COOP.txt, for testers.

    python tools/make_coop_pack.py PATH\\TO\\TN+Coop.exe [--out TerraNovaCoop_test.zip]

Left out: .git, the docs images, live/snaps, live/shots and local caches (.godot, __pycache__, *.import).
The TN+ Coop exe is not in this repo, so its path is given on the command line.
"""
import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = "TerraNovaCoop"  # folder inside the zip

SKIP_DIRS = {".git", ".godot", "__pycache__", "export", "movies_hd", os.path.join("live", "snaps"), os.path.join("live", "shots")}
SKIP_EXT = {".pyc", ".import", ".zip"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp"}

README = """TERRA NOVA COOP - TEST BUILD (prototype)
=======================================

Two players, one mission: the host plays the game, the guest drives a
teammate over Steam.


WHAT EACH PLAYER NEEDS
----------------------
- Your own copy of Terra Nova (Uplink draws the maps from it).
- Steam running, and the other player in your Steam friends.
- Godot 4.7, standard Windows version: https://godotengine.org/download/windows/
  Unzip it next to this folder (or set the GODOT variable to the Godot exe).
- The same files from this zip on both PCs (the version is checked when you join).

The host also needs:
- 64-bit Python 3 (https://www.python.org/downloads/), then: pip install numpy psutil
- TN+ Coop (the exe in this zip) to start the game.


HOST
----
1. Start the game with TN+ Coop, Display HD 848x480, English game.
2. Run "Live (prototype).bat". In the Uplink window, while the mouse is free
   (game menus, or press Y), click "Host online" at the top left.
   (Or run "Coop online - host (prototype).bat" instead of Live.)
3. Uplink opens. When it says ONLINE - CONNECTABLE, press F9 in its window
   to send a Steam invite to your friend.
4. Start or continue a mission. You play as usual.


GUEST
-----
1. Start Steam.
2. Run "Coop online - join (prototype).bat". A waiting screen opens.
3. Accept the host's invite in Steam (or use "Join game" on the host in
   your friends list).
4. When the host is in a mission, you drive the teammate nearest to the host.


CONTROLS (GUEST)
----------------
- W / S / A / D: move
- Mouse: look
- Left button: fire
- Gamepad: left stick move, right stick look, right trigger fire
- F8: next teammate


WHAT THE HUD SHOWS (GUEST)
--------------------------
- A crosshair.
- ARMOUR in %: green, then orange, then red as it drops.
- TEAMMATE #n: the teammate you drive.
- SUIT DESTROYED: your teammate is down, you switch to the next one in 3 s.
- NO TEAMMATE LEFT - watching the host: you see the host's view.
- At the top: ONLINE / OFFLINE and the Steam status. "ANOTHER COOP VERSION"
  means the two PCs do not have the same files.


KNOWN LIMITS
------------
- This is a prototype: expect bugs, glitches and crashes.
- It uses Steam's test app (App ID 480, "Spacewar"), so Steam may show you
  as playing Spacewar.
- English version of the game only.
- Windows only. Two players only.


SENDING LOGS BACK
-----------------
If something goes wrong, send us:
- Host: a copy of the text in the black console window (or a screenshot of it).
- Both: the Godot log, in
    %APPDATA%\\Godot\\app_userdata\\Terra Nova Uplink\\logs\\godot.log
  (paste that path in the Windows Explorer address bar).
- A few words on what you did and what happened, and a screenshot if you can.
"""


def skipped(rel: str) -> bool:
    parts = rel.split(os.sep)
    for i in range(1, len(parts)):
        if os.path.join(*parts[:i]) in SKIP_DIRS:
            return True
    ext = os.path.splitext(rel)[1].lower()
    if ext in SKIP_EXT:
        return True
    if parts[0] == "docs" and ext in IMAGE_EXT:
        return True
    return False


def coop_files():
    # in a git checkout: tracked files only (never local notes, captures or ignored files)
    try:
        import subprocess
        out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, check=True).stdout
        for rel in sorted(out.decode("utf-8").split("\0")):
            rel = os.path.normpath(rel) if rel else ""
            if rel and not skipped(rel) and os.path.isfile(os.path.join(ROOT, rel)):
                yield rel
        return
    except (OSError, subprocess.CalledProcessError):
        pass
    for d, dirs, files in os.walk(ROOT):
        rel_d = os.path.relpath(d, ROOT)
        dirs[:] = sorted(x for x in dirs if not skipped(os.path.normpath(os.path.join(rel_d, x, "_"))))
        for f in sorted(files):
            rel = os.path.normpath(os.path.join(rel_d, f))
            if not skipped(rel):
                yield rel


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the Terra Nova coop test zip.")
    ap.add_argument("coop_exe", help="path to the TN+ Coop exe (not in this repo)")
    ap.add_argument("--out", default=os.path.join(ROOT, "TerraNovaCoop_test.zip"), help="zip to write")
    a = ap.parse_args()
    if not os.path.isfile(a.coop_exe):
        print(f"TN+ Coop exe not found: {a.coop_exe}", file=sys.stderr)
        return 1
    out = os.path.abspath(a.out)
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in coop_files():
            src = os.path.join(ROOT, rel)
            if os.path.abspath(src) == out:
                continue
            z.write(src, TOP + "/" + rel.replace(os.sep, "/"))
            n += 1
        z.write(a.coop_exe, TOP + "/" + os.path.basename(a.coop_exe))
        z.writestr(TOP + "/README_COOP.txt", README.replace("\n", "\r\n"))
    print(f"{out}: {n + 2} files, {os.path.getsize(out) // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
