# Online co-op (prototype)

Two players, one mission, over Steam. The host plays the real game, the guest drives one of his squadmates from his own PC.

It's a prototype: expect bugs. Help, bugs, or looking for someone to play with: [Discord](https://discord.gg/AHpqNeT7s).

## What you need

- Windows, Steam running, and each other in your Steam friends.
- Your own Terra Nova (GOG or Steam). The host needs the English version (Steam's is).
- **[Terra Nova Uplink.exe](https://github.com/skw-1337/terra-nova-uplink/releases/latest)**: put it in an empty folder and run it. It downloads everything else and keeps it up to date. Windows may warn about an unknown app (not signed): More info, then Run anyway.

## Host

1. Click **HOST A GAME**. The game starts, then Uplink opens.
2. In the game, go to **Mission Outfitting** (the screen with the pilots). Or pick a mission in **Start at** first, then in the game: Load Game, `COOP Mission NN`.
3. Invite your friend from the list at the top right of Uplink.
4. When he has pressed **READY**, click **Outfit Complete** in the game and play.

## Guest

1. Click **JOIN A FRIEND**.
2. Click **JOIN** next to your friend (he must have clicked HOST A GAME).
3. Click **TAKE THIS COLUMN** on a squadmate, pick your pilot, suit and weapons, then **READY**.
4. When the mission starts, click in the window to take the mouse.

| Key | Action |
|---|---|
| W / S / A / D | move |
| Mouse | look |
| Left / right button | fire / lock a target |
| Space (hold) | jump jets |
| 1 - 4 | weapon |
| F8 | next squadmate |
| Enter | call the dropship |
| Y | free the mouse |

A gamepad works too (untick **Gamepad** in the launcher if you don't want it).

## If something goes wrong

- **Your friend isn't in the list**: you must be Steam friends, and he must have clicked HOST A GAME.
- **"Different versions"**: both close Uplink and click again, it updates.
- **The guest keeps firing**: a gamepad trigger that doesn't go back to zero. Untick **Gamepad**.
- **Anything else**: click **Report a bug** in the launcher and send the zip it puts on your desktop on [Discord](https://discord.gg/AHpqNeT7s), with a few words on what happened.

<details>
<summary>Without the launcher (developers)</summary>

Both: Godot 4.7 (standard Windows version) next to the `.bat` files of this repo (`main`). Host: also 64-bit Python 3 with `pip install numpy psutil`, and Terra Nova Plus built from its [`coop` branch](https://github.com/skw-1337/terra-nova-plus/tree/coop) (`src\build.bat`), started with Display HD 848x480.

- Host: in Mission Outfitting, run `Coop online - host (prototype).bat` and wait for ONLINE · CONNECTABLE.
- Guest: run `Coop online - join (prototype).bat`.

Logs: `%APPDATA%\Godot\app_userdata\Terra Nova Uplink\coop_logs`, and on the host `live\logs\coop_host_*.log`.
</details>
