<img src="assets/icon.svg" width="64" height="64" alt="">

# wow-photomode

**PhotoMode** is an addon for **WoW: Forever** (Interface 16001). Click its button, or type `/photo`, and it will:

1. Hide every unit name, title, guild name, nameplate and chat bubble. Only CVars that exist on your client are changed.
2. Hide the UI.
3. Switch to first person. It waits until the camera has actually arrived and stopped moving, then waits another half second so the character fade is finished (no ghost of your head). If the camera has not settled after 3 seconds, it takes the shot anyway and says so in chat. It also raises `cameraZoomSpeed` for the zoom-in, if that CVar exists, and puts it back afterwards.
4. Take a screenshot.
5. Put everything back the way it was: every CVar, the UI and your camera distance.

It refuses to start in combat. If combat starts partway through, it cancels the photo. It also restores everything on errors, on reload and on logout.

## Install

Your AddOns folder is `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns`.

Link the addon folder instead of copying it, so a `git pull` updates the game copy too. Open **Command Prompt as Administrator** and run this (change the second path to wherever this repo is):

```bat
mklink /J "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\PhotoMode" "C:\path\to\wow-photomode\PhotoMode"
```

Link to the `PhotoMode` folder inside the repo (the one that holds `PhotoMode.toc`), not to the repo root. Restart the game or `/reload`, and enable **PhotoMode** in the AddOns list on the character screen.

To uninstall, delete the junction: `rmdir "C:\Program Files (x86)\...\AddOns\PhotoMode"`. This removes only the link, not the repo.

## Use

| Command | What it does |
|---|---|
| click the button / `/photo` | take a clean screenshot |
| drag the button | move it (the position is saved per account) |
| `/photo debug` | open a window listing every candidate CVar, whether it exists on this client and its value, plus camera info |
| `/photo restore` | put back settings left over from an interrupted photo |
| `/photo forget` | give up on a restore that keeps failing (new photos are blocked until it succeeds or is forgotten) |
| `/photo reset` | move the button back to its default spot |

The `/photo debug` window opens with all its text already selected. Press **Ctrl+C** to copy it (or **Ctrl+A** first if you clicked inside it). Close it with the X button or **Esc**, and drag it to move it.

The last report is also saved in `C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account\<ACCOUNT>\SavedVariables\PhotoMode.lua`, under the key `lastDebug`. The game writes that file when you `/reload` or log out.

Screenshots go to the game's usual `Screenshots` folder.

## Tuning

Delays, the zoom wait (poll rate, settle frames, post-zoom delay, nudges, 3-second cap), the zoom amount and zoom speed, the alpha fallback mode, the debug window size, the button size and icon, and the full CVar candidate list are in `PhotoMode/Config.lua`.

## Tests

`tests/run.lua` runs the core logic against a mocked WoW API. Run it from the repo root with any Lua 5.1+:

```
lua tests/run.lua
```
