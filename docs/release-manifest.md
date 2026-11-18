# release.json: what the launchers install (since 2.7.1)

One small file decides what every launcher from 2.7.1 on installs:
`https://raw.githubusercontent.com/skw-1337/terra-nova-uplink/release/release.json`, on a branch of its own
(`release`) that holds nothing else (plus the beta's pictures). Changing it is the release; pushing code to
`main` / `stable` / `beta` alone changes nothing for 2.7.1+ players (2.7 launchers still follow `stable`'s head
until they have updated themselves to 2.7.1).

## Schema 1

```json
{
 "schema": 1,
 "repo": "skw-1337/terra-nova-uplink",
 "channels": {
  "stable": {
   "version": "2.7.1",                     // semver; pre-releases: 2.8.0-beta.1 < 2.8.0-beta.2 < 2.8.0
   "launcher": "2.7.1",                    // VERSION in launcher/TerraNovaUplink.cs at that commit
   "min_launcher": "2.7.1",                // an older launcher updates itself first, then installs the rest
   "uplink": { "ref": "<40-hex commit>", "tree_sha256": "<64-hex>", "files": { "path": "<sha256>", ... } },
   "tnplus":      { "ref": "<commit>", "tree_sha256": "<64-hex>", "version": "1.2.6" },
   "tnplus_coop": { "ref": "<commit>", "tree_sha256": "<64-hex>", "version": "1.2.6" },
   "changelog": [ { "section": "Launcher", "items": [ "..." ] } ]
  },
  "beta": { "...same fields...",
   "invitation": { "title": "Uplink 2.8 is in beta", "subtitle": "...",
                   "images": [ { "url": "https://raw.githubusercontent.com/skw-1337/terra-nova-uplink/release/beta/1.jpg",
                                 "sha256": "<64-hex>", "caption": "..." } ] } }
 },
 "deps": { "godot": { "sha256": "..." }, "python": { "sha256": "..." }, "numpy": { "sha256": "..." }, "psutil": { "sha256": "..." } }
}
```

- `tree_sha256`: SHA-256 of the lines `"<sha256 of the file> <path>\n"` of every file of GitHub's archive of
  that commit (top folder removed, paths with `/`, ordinal order; `.godot/`, `__pycache__/` left out). The
  launcher unpacks the archive into `components\updates`, computes it, and installs nothing that differs.
  Archives are fetched by commit (`codeload.github.com/<repo>/zip/<ref>`), never by branch.
- `files` (Uplink only, optional): the same hashes one by one; lets the launcher tell files a player changed by
  hand (kept as `<name>.user-modified`) on an installation made before release.json existed. After an install
  the launcher keeps its own list (`components\uplink\.release-files`).
- `deps` (optional): SHA-256 of the fixed downloads (Godot zip, Python embeddable zip, the two wheels); checked
  when given.
- Only `https://` addresses of this project's GitHub are taken (codeload, github.com, raw); anything else in the
  file is ignored. Unknown fields are ignored. A channel missing a field is left out.

## What the launcher does with it

- Follows `stable`; with Settings > Updates > Beta updates on, the newer of `beta` and `stable` (no beta, or a
  beta older than stable: stable). A beta tester whose beta became final is asked once "keep getting betas?".
- Not opted in and a beta newer than stable and than what is installed: the invitation is shown once per line
  (2.8, 2.9...), then a badge at the foot of the side bar opens it again.
- The launcher of the channel is built from that commit's sources (its own `build.bat` line), started once with
  `--selftest`, then swapped in (the old exe is kept in `components\previous\launcher`) and restarted; then Uplink's
  files and the TN+ builds are staged, checked, and swapped in together (the replaced ones go to
  `components\previous`: Tools > Roll back to previous version). Settings of each version are kept in
  `components\settings\<version>`; going back to an older version puts its own back.
- Never while anything runs from `components\`, never with `no_update.txt`, never two launchers at once
  (`components\updates\update.lock`). Offline, HTTP 403/429 (rate limit), timeouts, a cut or wrong download, a
  failed build, a read-only folder, a full disk: nothing is replaced, the installed version plays, one notice.
- No decision uses the PC's clock (a PC with a very wrong clock fails HTTPS and simply stays as it is).
- release.json not published yet (404) and nothing installed from one: the 2.7 behaviour (branch heads).

## Making one

```
python tools/release/make_manifest.py release.src.json -o release.json --previous release.json --verify-remote
```

`release.src.json` names, per channel, `version`, the git revisions `uplink`, `tnplus`, `tnplus_coop`,
`min_launcher`, `changelog`, `invitation` (pictures as `"file": "beta/1.jpg"` next to it). The script resolves the
commits, reads the launcher's version, hashes the trees and refuses an inconsistent file (version not the
launcher's or project.godot's, min_launcher above the launcher). `--verify-remote` compares with GitHub's own
archives: run it once the commits are pushed, before release.json is.

Rules: a new version number for any change of a channel (TN+ included); never remove `beta` while it is newer
than `stable` (testers would be sent back): promote it (`stable` = the final version) instead.

## Checks

`TN_UPLINK_TEST_SERVER=http://127.0.0.1:PORT` (loopback only, ignored otherwise) sends every GitHub request of a
launcher to `tools/release/fake_github.py`, which can also break chosen requests (404, 403, 429, slow, cut,
corrupt). `TN_UPLINK_TEST_FREE=<bytes>` (only together with it) pretends the disk has that much room.
Without a window: `--install play` (exit 0; 3 = the launcher replaced itself, run again), `--rollback`,
`--selftest` (prints the version), `--cooptext "<Uplink co-op line>"...` (the session line it gives).
`docs/release.src.example.json` / `docs/release.example.json`: the spec and the file it gives for 2.7.1 + 2.8.0-beta.1.
