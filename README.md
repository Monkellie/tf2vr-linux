# Titanfall 2 VR on Linux

Play [CircuitLord's Titanfall 2 VR mod](https://github.com/CircuitLord/CircuitLordVRModInstaller) on Linux. The official installer only runs on Windows. This repo does the same job on Linux, and fixes the crashes the mod hits under Proton.

- Your normal Titanfall 2 stays unmodded. The mod lives in its own `TF2VR` profile, with its own campaign save.
- Everything comes from the official release links, checked against the official checksums. This repo contains no game or mod files.

## What you need

- An **x86_64** Linux PC with a current distro (glibc 2.38 or newer, [details](#which-headsets-and-distros-work)). A standalone Steam Frame or other ARM device can't run this ([why](#can-i-play-on-a-steam-frame-or-other-arm-device)).
- **Titanfall 2 on Steam**
- **Proton Experimental**, installed in Steam: Library → search "Proton Experimental" → Install
- A **VR runtime**: SteamVR (Settings → OpenXR → "Set SteamVR as OpenXR runtime"), or WiVRn / Monado
- A few tools:
  - Arch, CachyOS, EndeavourOS: `sudo pacman -S --needed python unzip cabextract`
  - Debian, Ubuntu: `sudo apt install python3 curl unzip cabextract`
  - Fedora: `sudo dnf install python3 curl unzip cabextract`
- About 2 GB of free disk space

## Install

1. **Start Titanfall 2 once from Steam, the normal way.** Sign in to the EA app, wait for the main menu, then quit.
2. **Run the installer:**
   ```sh
   git clone https://github.com/Monkellie/tf2vr-linux.git
   cd tf2vr-linux
   ./install.sh
   ```
   It checks your system first and tells you if anything is missing.
3. **Restart Steam**, then set **Titanfall 2 → Properties → Compatibility → Proton-TF2VR**.

## Play

Put your headset on, then run `tf2vr` in a terminal or pick **Titanfall 2 VR** in your app menu. It starts SteamVR and the EA app for you, and closes the EA app when you quit.

> Steam's **Play** button always starts the normal, flat game. VR only starts through `tf2vr` or the Titanfall 2 VR menu entry.

For mod settings, controls and help with the mod itself, see [CircuitLord's Discord](https://discord.gg/MTKwud2cCP).

## Update

```sh
cd tf2vr-linux
git pull
./install.sh
```

## Uninstall

Switch Titanfall 2 back to your old Proton in Steam (Properties → Compatibility), then run `./install.sh --uninstall`. Your VR campaign saves are kept.

## If something goes wrong

| What you see | What to do |
|---|---|
| The game starts flat | You used Steam's Play button. Start VR with `tf2vr`. |
| `tf2vr: command not found` | Run `~/.local/bin/tf2vr`, or [add `~/.local/bin` to your PATH](#arch-cachyos-and-other-arch-based-distros). |
| `install.sh` prints `FAIL` | Install what it names, then run `./install.sh` again. |
| The game says you're logged out of Origin, then quits | [Update](#update) to the latest scripts. If the EA app's window asks you to sign in, do. ([why](#why-does-the-launcher-manage-the-ea-app)) |
| Crash with code `0xC0000409` (3221226505) | Check Titanfall 2 is set to Proton-TF2VR in Steam, then run `./install.sh --refresh-proton`. ([why](#why-does-it-need-its-own-copy-of-proton)) |
| Crash in `MSVCP140.dll` right after the mod loads | Run `./install.sh` again. ([why](#why-does-it-install-a-newer-vc-runtime)) |
| `install.sh`: `couldn't install the VC++ runtime` | Install `cabextract` and run `./install.sh` again, or run `protontricks 1237970 vcrun2022`. |
| `engine.txt` stops at `stage=openxr_instance` | Start SteamVR (or WiVRn / Monado), check the headset is detected, and check it's set as the OpenXR runtime. |
| The game runs, but the headset shows nothing | VR needs DXVK. Check `vulkaninfo --summary` shows Vulkan 1.3. ([why](#why-does-the-launcher-ignore-some-of-my-settings)) |
| A small white EA box stays on screen, or `install.sh` says the EA app is running | Run `tf2vr` once; it clears what older versions left behind. ([why](#why-does-the-launcher-manage-the-ea-app)) |
| `Another mod replaced DirectX files` | Remove `dxgi.dll` and `d3d11.dll` (ReShade and similar) from the game folder. |
| `write dump: Invalid parameter` | Harmless; look for the real cause in the logs below. ([why](#what-does-write-dump-invalid-parameter-mean)) |
| The game closes about a minute after it starts, every time | Happens when your Steam library is on another drive. [Update](#update) to the latest scripts. |
| Achievements don't unlock in VR | [Update](#update) to the latest scripts. ([why](#why-does-the-launcher-manage-the-ea-app)) |
| Discord shows SteamVR instead of Titanfall 2 | [Update](#update) to the latest scripts. ([why](#why-does-discord-show-steamvr-instead-of-titanfall-2)) |
| Steam isn't found | Run `STEAM_DIR=/path/to/Steam ./install.sh`. |
| `Proton's Wine can't run directly on this system` | You're on an ARM device. ([see here](#can-i-play-on-a-steam-frame-or-other-arm-device)) |
| `install.sh`: `glibc … is too old` | Your distro release is too old for the current Proton. Upgrade to one with glibc 2.38 or newer. ([which ones](#which-headsets-and-distros-work)) |

**Still stuck?** [Open an issue](https://github.com/Monkellie/tf2vr-linux/issues) with these files. Collect them after the game has closed, or they'll be cut off:
- `~/.local/state/tf2vr/launch.log`
- `Titanfall2/TF2VR/plugins/Titanfall2VR-data/engine.txt`
- the newest `Titanfall2/TF2VR/logs/nslog*.txt`
- the newest folder in `Titanfall2/TF2VR/crashes/`

`Titanfall2/` is `<Steam library>/steamapps/common/Titanfall2`. For a Proton log as well, launch with `tf2vr --proton-log`; it's saved to `~/.local/state/tf2vr/steam-1237970.log`.

## FAQ

### What does `install.sh` actually do?

It follows the official installer (`Titanfall2Installer.cs`) step by step:
- It reads the current mod release from CircuitLord's `manifest-v3.json`, and the Northstar version the official installer pins at that release.
- It downloads both and checks their SHA-256 checksums.
- It runs the mod's own `asset_patcher.exe` under Proton, which builds the mod's game assets from your game files, then checks every file it built.
- It lays the files out the same way: Northstar and the mod in `Titanfall2/TF2VR`, and `Titanfall2VRLauncher.exe` next to the game. `Titanfall2.exe` is never touched.

On top of that, it:
- copies Proton Experimental to `compatibilitytools.d/Proton-TF2VR` and applies the audio fix to that copy only
- installs Microsoft's current VC++ runtime into the Titanfall 2 prefix, if the one there is too old
- adds the `tf2vr` command in `~/.local/bin` and the Titanfall 2 VR app-menu entry
- adds `~/.local/share/tf2vr/discord-presence.py`, which the launcher uses to set your [Discord status](#why-does-discord-show-steamvr-instead-of-titanfall-2)

`./install.sh --check` runs only the checks and changes nothing. When you update, it installs a new mod release if there is one, and removes files the old version used that the new one doesn't. `./install.sh --force` reinstalls from scratch.

### Why does it need its own copy of Proton?

For the audio fix. The mod captures game audio through `ActivateAudioInterfaceAsync("VAD\Process_Loopback")`, probably for haptics. Wine rejects that device, and the mod then crashes with `0xC0000409`. [polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix) found that changing one jump in Proton's `mmdevapi.dll` (6 bytes at offset `0x369E`) sends the request to the default playback device instead, where Wine's PulseAudio driver already supports loopback capture.

The fix goes into the private copy only, after checking the surrounding bytes match, so your other games are untouched. The copy is frozen, so Steam updates can't break it. To rebuild it from a newer Proton Experimental, run `./install.sh --refresh-proton`. If the new `mmdevapi.dll` doesn't match the fix, the script refuses rather than guessing; keep the old copy and open an issue.

Steam has to be set to Proton-TF2VR as well, because normal and VR launches share one Wine prefix, and switching Wine versions on a prefix breaks things.

### Why does it install a newer VC++ runtime?

The EA app installs `msvcp140.dll` 14.34 into the prefix. The mod is built with a newer compiler, and with that older runtime its `std::mutex` use reads a null pointer, so it crashes in `MSVCP140.dll` right after loading. Runtime 14.40 or newer fixes it, which is what an up-to-date Windows PC has.

Microsoft's installer sometimes does nothing under Wine. Then `install.sh` copies the DLLs out of it with `cabextract` or `bsdtar`, the way winetricks does. The runtime stays in the prefix after you uninstall; it's harmless.

### Why can't Steam's Play button start VR?

Steam always starts `Titanfall2.exe`, the normal game. Setting Proton-TF2VR in Steam only picks the Proton build. The VR mod starts through Northstar's launcher instead, the way the official installer's Play button does it. `tf2vr` does exactly that: `crash_monitor.exe` starts `Titanfall2VRLauncher.exe` with the TF2VR profile and the arguments from the mod's `launch.json`.

The launcher also sets `SteamGameId=1237970`. Proton's `steam.exe` only sets up its VR bridge (the OpenXR and Vulkan data `wineopenxr` reads from `HKCU\Software\Wine\VR`) for programs it thinks Steam started.

Copying CircuitLord's installer over `Titanfall2.exe` to run it in Proton is a dead end, and you don't need it: `install.sh` does the installer's job. Verify the game files in Steam to get `Titanfall2.exe` back, and remove any `PROTON_USE_WINED3D` or `WINEDLLOVERRIDES` launch options you added for it.

### Why does the launcher manage the EA app?

Titanfall 2 needs a signed-in EA app, and it checks the sign-in once, when it starts. So the launcher:
- **Starts the EA app and waits until it's signed in**, then starts the game. Older versions waited a fixed 8 seconds. When the EA app took longer, the game decided you were logged out of Origin and quit (exit code 274).
- **Tells the game which EA product it is.** When Steam starts Titanfall 2, EA's launcher gives the game `ContentId=Origin.OFR.50.0001456`, the EA offer your Steam copy is linked to. Without it, the game falls back to its built-in ID, the EA app can't match the session to your copy, and it refuses every achievement ("Entitlement not found" in `EADesktopVerbose.log`). The launcher sets the same value. The EA app still checks that you own the game.
- **Deletes the EA app's `backgroundservice.ini` first.** A session that was ended by force leaves this file behind. If the next EA background service happens to get the same Wine process ID, the EA app trusts the old port in the file and signs in 20 seconds late.
- **Closes the EA app and its Wine session when you quit.** `proton run` doesn't return while the EA app is open, and Steam keeps showing Titanfall 2 as running. So the launcher follows `crash_monitor.exe` instead, reports the game's exit code, and then ends the session.
- **Cleans up after Wine.** With the kernel's ntsync driver, which Proton 11 uses whenever `/dev/ntsync` exists, Wine processes that are waiting when the wineserver exits never wake up again. One of them is `explorer.exe`, whose tray window keeps showing the EA icon: the white box. The launcher ends whatever outlives the wineserver, after each session and before the next launch.

### Why does the launcher ignore some of my settings?

The launcher doesn't go through Steam, so Steam launch options don't apply, but variables you set globally (for example in `/etc/environment` or `~/.config/environment.d`) do. It removes these, with a warning:
- `PROTON_USE_WINED3D`: VR needs DXVK. Proton's OpenXR bridge hands the game's frames to the headset as DXVK textures, so with wined3d the headset shows nothing. If Titanfall 2 only starts with wined3d, your GPU or driver can't run DXVK, which needs Vulkan 1.3.
- `PROTON_ENABLE_WAYLAND`: the EA app and VR are only tested with Wine's X11 driver.
- `MANGOHUD`: overlays aren't tested with the EA app and VR.

### Why does Discord show SteamVR instead of Titanfall 2?

Discord recognises games by their program name, and it doesn't know `Titanfall2VRLauncher.exe`. So all it detects during a VR session is SteamVR's status window, or `crash_monitor`. The mod's own Discord plugin can't fix that: it looks for Discord on a Windows pipe, and under Wine nothing connects that pipe to Linux Discord. Its `[DSCRD-RPC] waiting for handshake...` line in the nslog never gets an answer.

So the launcher sets your status itself, through Discord's local socket: **Playing Titanfall 2 VR**, with the chapter, difficulty and play time, under Titanfall 2's icon. Discord ranks a status with details like these above apps it only detected, so this one shows instead of SteamVR, for you and for your friends. It works with the Discord app (native, Flatpak or Snap) and with Vesktop, and it clears when the game closes. `launch.log` says `Discord: showing "Playing Titanfall 2 VR"` once it's connected.

SteamVR can still appear as a second activity on your own profile. To remove it completely, turn off its detection in Discord's **Settings → Registered Games**.

### Arch, CachyOS and other Arch-based distros

- **`~/.local/bin` isn't on your PATH by default**, so a plain `tf2vr` isn't found. Use the app-menu entry, run `~/.local/bin/tf2vr`, or add it to your PATH: `export PATH="$HOME/.local/bin:$PATH"` in `~/.bashrc` or `~/.zshrc`, or `fish_add_path ~/.local/bin` in fish.
- **`python` and `unzip` aren't part of a minimal install:** `sudo pacman -S --needed python unzip cabextract`.
- **A few libraries come from your system**, because the scripts run Proton directly rather than inside Steam's runtime: `gnutls` (the EA app needs it to sign in), `vulkan-icd-loader`, `libx11` and `libpulse`. `install.sh` checks for them.
- **The audio fix needs a PulseAudio-compatible sound server.** With PipeWire, install `pipewire-pulse`.
- **Arch and CachyOS kernels ship ntsync**, which made older versions of these scripts leave hung Wine processes behind after you quit. [Update](#update) to the latest scripts.

### Can I play on a Steam Frame or other ARM device?

Not on the headset itself. A standalone Steam Frame is an ARM device, so it runs x86 games through FEX emulation inside Steam's own runtime. These scripts start Proton's x86 Wine directly, outside Steam, which can't work there. `install.sh` stops with "Proton's Wine can't run directly on this system" before changing anything.

**Instead, run the game on a PC and stream it to the headset:**
- **From an x86_64 Linux PC:** follow [Install](#install) on the PC and make SteamVR the active OpenXR runtime. Connect the headset to the PC's SteamVR through Steam's PC VR streaming (on the Frame, with its wireless adapter). Then start SteamVR on the PC and run `tf2vr`.
- **From a Windows PC:** you don't need these scripts. Use [CircuitLord's official installer](https://github.com/CircuitLord/CircuitLordVRModInstaller), connect the headset to SteamVR, and press Play in the installer.

Streaming a Steam Frame to Linux SteamVR hasn't been tested with these scripts yet. Linux SteamVR ships the Frame's headset and controller profiles and the Steam Link streaming driver, so it should work like any other SteamVR headset. Reports welcome.

### Which headsets and distros work?

Tested on PikaOS (Debian sid) on Wayland, with an NVIDIA GPU, a Valve Index, SteamVR 2.17.10, Proton Experimental 11.0 (2026-09-24), mod 1.0.10 and Northstar 1.31.13. The main menu and the campaign run in VR with tracked controllers and audio.

- **Other headsets:** polar421 has played the campaign on a Quest 3S through WiVRn with a similar setup. With these scripts, a tethered WiVRn user has got as far as the mod finding the headset and controllers.
- **Other distros:** anything x86_64 with **glibc 2.38 or newer** should work: Ubuntu 24.04+, Linux Mint 22+, Pop!_OS 24.04+, Debian 13+, Fedora 39+, and current Arch and its derivatives (see the [Arch notes](#arch-cachyos-and-other-arch-based-distros)). Steam runs Proton inside its own runtime, which brings a newer glibc, but these scripts run Proton outside it, so your system's glibc has to be new enough. Ubuntu 22.04, Mint 21 and Pop!_OS 22.04 (2.35) and Debian 12 (2.36) are too old. `install.sh` checks this.
- **Untested:** SteamOS on x86, and Flatpak Steam (`~/.var/app/com.valvesoftware.Steam/.local/share/Steam`).
- **Two GPUs:** the game has to render on a GPU that has a monitor attached, and it has to be the same GPU your VR runtime uses.

Reports welcome.

### What does `write dump: Invalid parameter` mean?

Nothing on its own. When the game quits with an error, `crash_monitor.exe` tries to save a memory dump of it, but the game has already exited, and Wine refuses. Look at the `process_exit … code=` line above it in `monitor.txt`, and at the Northstar log, for the real reason.

## Credits

- **[CircuitLord](https://github.com/CircuitLord/CircuitLordVRModInstaller)** for the Titanfall 2 VR mod and its installer (MIT). Everything here follows that installer.
- **[polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix)** for getting the mod running on Proton first, and for finding the `mmdevapi.dll` audio fix.
- **[Northstar](https://github.com/R2Northstar/Northstar)**, the mod loader the VR mod runs on.

This is a community project. It isn't affiliated with or endorsed by Respawn, EA, Valve or CircuitLord.

## License

[MIT](LICENSE): use, copy, modify, share and sell it freely, as long as you keep the license notice. The mod, Northstar and the game have their own licenses and aren't included here.
