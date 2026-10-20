# Online co-op (prototype)

Two players, one mission, over Steam. The host plays the real game. The guest drives one of the host's squadmates from his own PC, in Uplink.

It's a prototype: expect bugs. Windows only, two players, English game only for now.

Help, bug reports, or looking for someone to play with: [Discord](https://discord.gg/AHpqNeT7s).

## The easy way: Terra Nova Coop

**`Terra Nova Coop.exe`** does everything for both players. Put it in an empty folder and start it:

- **HOST A GAME**: downloads what's missing (Uplink, Godot, Python for the bridge, and builds TN+ Coop), starts the game without TN+'s menu, waits for it to load, then opens Uplink with the Steam lobby. Invite your friend from the list at the top right of Uplink's window.
- **Mission (host)**: pick a campaign mission instead of going through the game's menus. The launcher writes a save named `COOP Mission NN` in a free slot (never over one of yours), made from your most advanced save (your squad and equipment) and set on that mission. In the game: Load Game, then that save.
- **JOIN A FRIEND**: downloads Uplink and Godot, then opens the guest window. Your friend's name shows up there once he hosts: click **JOIN**.

Everything goes in that folder (about 250 MB once installed). Before each game it checks GitHub and updates, so both PCs stay on the same version. It finds the game on its own (GOG or Steam, the English one first); **Change...** picks another folder. To build it yourself: `launcher\build.bat` (C# compiler that comes with Windows).

The rest of this page is the manual way, and what the launcher does for you.

## What each player needs

| | Host | Guest |
|---|---|---|
| Terra Nova (GOG or Steam, English) | yes | yes |
| Steam running, the other player in your friends | yes | yes |
| [Godot 4.7](https://godotengine.org/download/windows/), standard Windows version | yes | yes |
| Uplink, `coop` branch | yes | yes |
| 64-bit [Python 3](https://www.python.org/downloads/) + `pip install numpy psutil` | yes | no |
| Terra Nova Plus, `coop` build | yes | no |

Both players must use the same Uplink files. The version is checked when the guest joins. If one of you updates, the other updates too.

## Install Uplink (both players)

1. Download https://github.com/skw-1337/terra-nova-uplink/archive/refs/heads/coop.zip and unzip it.
2. Unzip Godot and put **`Godot_v4.7.x-stable_win64.exe`** (not the `console` one) inside the `terra-nova-uplink-coop` folder, next to the `.bat` files. A `Godot...` subfolder next to the `.bat` files works too.
3. Don't open Godot by itself: that only shows its project manager. Always start Uplink with the `.bat` files.

The first start takes 20 to 30 seconds while Godot prepares its files.

If Uplink can't find the game, it asks for the game folder (the one that contains `TNOVA`). On the Steam edition the maps are only inside the CD image (`_ISO\TNF108.ISO`). Uplink copies them out by itself the first time, so the first mission takes a few more seconds to load.

## Host

1. Get the co-op build of Terra Nova Plus: download https://github.com/skw-1337/terra-nova-plus/archive/refs/heads/coop.zip, unzip it, and double-click **`src\build.bat`**. It builds `src\TNPlus.exe` with the C# compiler that comes with Windows.
2. Start the game with that `TNPlus.exe`, Display **HD 848x480**. It doesn't touch your normal game files: the co-op code goes in a copy next to the tool.
3. In the game, go to the **Mission Outfitting** screen (the one with the pilots).
4. Double-click **`Live (prototype).bat`** in the Uplink folder. Leave its black console window open.
5. Click **Host online** at the top left (press `Y` first if the mouse is taken). Wait for **ONLINE · CONNECTABLE**.
6. Tell your friend to join (see below). `F9` opens the Steam invite, but only if Steam's overlay works in Uplink. It usually doesn't, so the guest joining from his friends list is the reliable way.
7. When your friend has taken a column and pressed **READY**, click **Outfit Complete** in the game and play as usual. The **Guest column** button at the top left locks his choices.

## Guest

1. Start Steam.
2. Double-click **`Coop online - join (prototype).bat`**. A waiting screen opens.
3. In your Steam friends list, click the arrow next to the host's name, then **Join game**. The host shows as playing "Spacewar": that's Steam's test app, it's normal. **Join game** only appears while your Uplink is open.
4. In the lobby, click **TAKE THIS COLUMN** on a squadmate, then pick your pilot, suit, weapons and ASF. The host sees your name, your face and your choices on his screen. Press **READY** when you're done. The chat is at the bottom right.
5. When the host starts the mission, click in the window to take the mouse.

### Guest controls

| Key | Action |
|---|---|
| W / S / A / D | move |
| Mouse | look |
| Left button | fire |
| Right button | lock a target |
| Space (hold) | jump jets (they use energy) |
| Shift + direction | jump |
| 1 - 4 | weapon |
| F8 | next squadmate |
| Enter, or **CALL DROPSHIP** | call the dropship at the end of the mission |
| Y | free the mouse |

A gamepad works too: left stick move, right stick look, right trigger fire, left trigger jets, A jump, RB lock.

## If something goes wrong

| Problem | Fix |
|---|---|
| "Godot 4.7 not found" | The Godot exe isn't next to the `.bat` files (or in a `Godot...` folder there). Move it. |
| F9 does nothing | Normal, Steam's overlay doesn't open in Uplink. Use the **Invite** list in Uplink (host), or **JOIN** in the guest window. |
| No **Join game** on the host | The guest's Uplink must be open first, and you must be Steam friends. |
| "ANOTHER COOP VERSION" | You don't have the same Uplink files. Both download the zip again. |
| The guest's suit keeps firing | Unplug a gamepad whose trigger doesn't go back to zero. |
| Brown ground, no terrain for the guest | Update Uplink: older versions didn't read the Steam edition's maps. |

To report a bug, send the newest file in `%APPDATA%\Godot\app_userdata\Terra Nova Uplink\coop_logs` (paste that path in the Explorer address bar). The host also sends the newest `live\logs\coop_host_*.log` in the Uplink folder. Add a few words on what happened, and a screenshot if you can.
