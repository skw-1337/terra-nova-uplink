# Terra Nova Uplink

*Terra Nova: Strike Force Centauri* (1996) redrawn in modern 3D. Two ways to use it:

- **Map viewer**: fly around every map of the game.
- **Live mode** (prototype): play the real game in DOSBox while Uplink redraws it live on your graphics card, cockpit included.

It reads everything from your own copy of the game (GOG or Steam). No game files are included.

*Version française : [README.fr.md](README.fr.md)*

![The red planet](docs/red_planet.jpg)

| | |
|---|---|
| ![Planetrise over the moon](docs/moon_planetrise.jpg) | ![Ships at the dock](docs/dock_ships.jpg) |
| ![The Bishop farm](docs/farm.jpg) | ![Biped mech](docs/biped_mech.jpg) |
| ![Storm sky](docs/storm.jpg) | ![Dawn](docs/dawn.jpg) |
| ![Power suit](docs/power_suit.jpg) | ![Model gallery](docs/model_gallery.jpg) |

## Map viewer

1. Have the game installed (GOG or Steam).
2. Get [Godot 4.7](https://godotengine.org/download/windows/) (standard version) and unzip it.
3. Download this repo (**Code** → **Download ZIP**), unzip it and double-click **`Map viewer.bat`**.

If the game isn't found, Uplink asks for its folder. The first time you open a map it takes a few seconds.

| Key | Action |
|---|---|
| Right mouse button + mouse | look around |
| WASD / ZQSD | move |
| Space / Ctrl | up / down |
| Shift | faster |
| Mouse wheel | speed |
| Tab | mission list |
| F2 / F3 / F4 | labels / mission markers / trees |

What's in it:

- All 37 campaign missions, training, the two cut missions, the mission generator maps and the demos
- The game's own ground textures, 3D models, soldiers, forests and skies
- A gallery of all 119 3D models (last entry in the list)

Fun find: there are Easter Island heads hidden on the red planet in *Operation Pigpen*.

## Live mode (prototype)

The game keeps running in DOSBox, so it's still the real game you play. A small Python bridge reads its state from DOSBox's memory about 120 times a second (camera, units, soldiers' joints, shots, explosions, sky, cockpit screen), and Uplink draws the same scene on the graphics card, with the game's own cockpit on top. You play from Uplink's window: your keys and mouse go back to the game.

![The game in DOSBox and Uplink, same camera](docs/live_prototype.png)

The cockpit, in the game (top) and over Uplink's 3D (bottom):

![The cockpit, game and Uplink](docs/live_hud.png)

1. Install 64-bit [Python 3](https://www.python.org/downloads/), then run `pip install numpy psutil`.
2. Start the game with [Terra Nova Plus](https://github.com/skw-1337/terra-nova-plus), Display **HD 848x480** (the live mode doesn't support 1280x720 yet).
3. Double-click **`Live (prototype).bat`**. It finds the mission in progress and opens Uplink on it. Starting from the menus works too.
4. Click in the window to take the mouse: the mouse looks around, the buttons fire and lock. `Y` or `Pause` gives you the game's cursor (cockpit buttons, map) and back. `F12` switches the "old school" look (the game's pixels and palette) on or off. Every other key goes to the game.

Close Uplink to stop. Menus, briefings and videos are shown as the game draws them. For HD cutscenes, `tools/upscale_movies.py` upscales the game's videos once on your PC (needs ffmpeg, Real-ESRGAN and RIFE).

It's a prototype: Windows only, a few weapon effects aren't drawn yet, and the bridge writes into the game's memory for your controls, like Terra Nova Plus does.

For modders: [technical notes](docs/formats.md).

## Legal

Fan project, not affiliated with the game's rights holders or with the Godot Foundation. Made with [Godot](https://godotengine.org). You need your own copy of the game. Code under the [MIT License](LICENSE).
