# Titanfall 2 VR on Linux

Play [CircuitLord's Titanfall 2 VR mod](https://github.com/CircuitLord/CircuitLordVRModInstaller) on Linux through Proton.

The official installer is a Windows program. `install.sh` does the same job on Linux:
- It downloads the same files: Northstar and the mod, both from their official release links, checked against the official SHA-256 checksums.
- It builds the mod's game assets from your own game files.
- It puts everything in the same separate `TF2VR` profile.

Your normal Titanfall 2 stays unmodded. This repo contains no game or mod files.

It also fixes the three things that make the mod crash under Proton (see [Why these fixes are needed](#why-these-fixes-are-needed)).

**Tested on:** PikaOS (Debian sid), Wayland, NVIDIA GPU, Valve Index with SteamVR 2.17.10, Proton Experimental 11.0 (2026-09-24), mod 1.0.10, Northstar 1.31.13. The main menu and the campaign run in VR with tracked controllers and audio.

**Other headsets:** polar421 has played the campaign on a Quest 3S through WiVRn with a similar setup. With these scripts, a tethered WiVRn user has got as far as the mod finding the headset and controllers through OpenXR, but hasn't reached gameplay yet. Reports welcome.

## Requirements

- An **x86_64** Linux PC. SteamOS on x86 should work but is untested. ARM devices, such as a standalone Steam Frame, aren't supported: these scripts start Proton's x86 Wine directly.
- Titanfall 2 **on Steam**, launched once normally so the EA app is installed and signed in
- **Proton Experimental** installed in Steam (Library → search "Proton Experimental" → Install)
- A working OpenXR runtime set as active:
  - **SteamVR:** Settings → OpenXR → "Set SteamVR as OpenXR runtime"
  - or WiVRn / Monado
- `python3`, `curl`, `unzip`, `sha256sum`, and preferably `cabextract` or `bsdtar` (the fallback for installing the VC++ runtime when Microsoft's installer fails under Wine; SteamOS already has `bsdtar`)
- About 2 GB of free disk space: 1.5 GB for the patched Proton copy, the rest for the mod

## Install

1. **Launch Titanfall 2 once from Steam the normal way.** Sign in to the EA app, wait for the main menu, then quit.
2. **Run the installer:**
   ```sh
   git clone https://github.com/Monkellie/tf2vr-linux.git
   cd tf2vr-linux
   ./install.sh
   ```
   It checks your setup first; `./install.sh --check` runs only the checks and changes nothing. Then it:
   - copies Proton Experimental to `compatibilitytools.d/Proton-TF2VR` and applies the audio fix to **that copy only**, so your other games are untouched
   - installs the current Microsoft VC++ 2015–2022 runtime into the Titanfall 2 prefix if the one there is too old
   - installs Northstar and the mod into `Titanfall2/TF2VR`, plus `Titanfall2VRLauncher.exe` next to the game
   - adds a `tf2vr` command (`~/.local/bin`) and a **Titanfall 2 VR** entry in your app menu
3. **Restart Steam**, then set **Titanfall 2 → Properties → Compatibility → Proton-TF2VR**. Normal and VR launches must use the same Proton, because switching between Wine versions on one prefix breaks things.
   This only selects the Proton build. **It doesn't turn on VR**: Steam's Play button still starts the normal, flat game.
4. *(Optional)* Press Play in Steam once to check the normal game still starts on Proton-TF2VR.

## Play

Turn on your headset, then run `tf2vr` in a terminal or pick **Titanfall 2 VR** from your app menu. The launcher:
- starts SteamVR, when SteamVR is your OpenXR runtime
- starts the EA app and waits for it
- launches the mod the same way the Windows installer's Play button does
- closes the EA app again when you quit

> **VR only starts through `tf2vr` or the Titanfall 2 VR menu entry.** Steam's Play button always starts the regular, flat game, even with Proton-TF2VR selected.

The VR campaign uses its own save, kept separate from your normal campaign.

For mod settings, controls and help with the mod itself, see [CircuitLord's Discord](https://discord.gg/MTKwud2cCP).

## Updating

Get the latest scripts, then run the installer again:
```sh
cd tf2vr-linux
git pull
./install.sh
```
The installer installs a new mod release (and the Northstar version the official installer pins) when there is one, and removes files the old version used that the new one doesn't. To rebuild from scratch, use `./install.sh --force`.

Proton-TF2VR is a frozen copy, so Steam updates can't break the audio fix. To rebuild it from a newer Proton Experimental, run `./install.sh --refresh-proton`. If the new build's `mmdevapi.dll` doesn't match the fix, the script refuses rather than guessing. In that case keep the old copy and open an issue.

## Uninstall

1. Switch Titanfall 2 back to your previous Proton in Steam (Properties → Compatibility).
2. Run `./install.sh --uninstall`.

This removes:
- the mod files it installed
- the launcher and the app menu entry
- Proton-TF2VR

It keeps your VR campaign saves (in the Wine prefix) and the logs in `Titanfall2/TF2VR/`. The newer VC++ runtime stays in the prefix; it's harmless.

## Troubleshooting

### Logs

| What | Where |
|---|---|
| Launcher output | `~/.local/state/tf2vr/launch.log` |
| Mod startup stages | `Titanfall2/TF2VR/plugins/Titanfall2VR-data/engine.txt` |
| Northstar log | `Titanfall2/TF2VR/logs/nslog*.txt` |
| Crash monitor (exit codes) | `Titanfall2/TF2VR/crashes/<session>/monitor.txt` |
| Proton log | run `tf2vr --proton-log` → `~/.local/state/tf2vr/steam-1237970.log` |

`Titanfall2/` means `<Steam library>/steamapps/common/Titanfall2`.

### Common problems

| Symptom | Cause / fix |
|---|---|
| The game starts flat (normal Titanfall 2) | You started it with Steam's Play button, which always starts the flat game. Start VR with `tf2vr` instead. If `tf2vr` doesn't exist, `install.sh` stopped before the end: run it again and read the error. |
| `install.sh`: `couldn't install the VC++ runtime` | Microsoft's installer did nothing under Wine, and neither `cabextract` nor `bsdtar` was available for the fallback. Make sure you're on the latest scripts (`git pull`), install `cabextract` (e.g. `sudo apt install cabextract`), then run `./install.sh` again. Alternatively: `protontricks 1237970 vcrun2022`, then `./install.sh`. |
| `install.sh`: `Proton's Wine can't run directly on this system` | These scripts start Proton outside Steam, which needs an x86_64 Linux PC. ARM devices aren't supported. |
| Northstar log: `EXCEPTION_ACCESS_VIOLATION … At: MSVCP140.dll + 0x13028`, and `engine.txt` stops at `stage=openxr_instance` | The VC++ runtime in the prefix is too old. Re-run `./install.sh`, which updates it. |
| Crash with exit code `0xC0000409` (3221226505) after the menu starts loading | The audio fix isn't active. Check Titanfall 2 is set to **Proton-TF2VR** in Steam, then run `./install.sh --refresh-proton`. |
| `engine.txt` shows `stage=openxr_instance` and nothing after, with no MSVCP140 crash | The OpenXR runtime isn't reachable. Make sure SteamVR (or WiVRn/Monado) is running, the headset is detected, and it's set as the active OpenXR runtime. |
| Launch hangs; the Northstar log mentions `LSX: connect()` or Origin | The EA app isn't signed in. Launch Titanfall 2 normally from Steam once, sign in, quit, and try again. |
| `install.sh` says Titanfall 2 or the EA app is running | Quit the game. If the EA app is stuck, close it from the system tray, or run `WINEPREFIX=<library>/steamapps/compatdata/1237970/pfx ~/.local/share/Steam/compatibilitytools.d/Proton-TF2VR/files/bin/wineserver -k` |
| Launcher warns `ignoring PROTON_USE_WINED3D`, or the game runs but nothing appears in the headset | VR needs **DXVK**: Proton's OpenXR bridge passes the game's frames to the headset as DXVK textures, so wined3d can't work, and the launcher ignores `PROTON_USE_WINED3D`. If Titanfall 2 only starts with wined3d, your GPU or driver can't run DXVK, which needs Vulkan 1.3. Check `vulkaninfo --summary`. |
| You copied CircuitLord's installer over `Titanfall2.exe` to run it in Proton | You don't need to; `install.sh` does the installer's job. Verify the game files in Steam to restore `Titanfall2.exe`, and remove any `PROTON_USE_WINED3D` / `WINEDLLOVERRIDES` launch options you added for it. The installer is a WPF app, which is why it seemed to need wined3d. |
| `Another mod replaced DirectX files` | Remove `dxgi.dll` / `d3d11.dll` from the game folder (ReShade and similar). They take over the frame presentation that VR rendering needs. |
| Steam isn't found | Point the installer at it: `STEAM_DIR=/path/to/Steam ./install.sh`. Flatpak Steam lives at `~/.var/app/com.valvesoftware.Steam/.local/share/Steam`, but it's untested. |

## Why these fixes are needed

1. **The installer is Windows-only.** `install.sh` follows `Titanfall2Installer.cs` from the official installer step by step:
   - It reads the current mod release from `manifest-v3.json`, and the pinned Northstar version from the installer source at the matching commit.
   - It runs the mod's own `asset_patcher.exe` under Proton, then checks every file it builds against the mod's checksums.
   - It lays the files out exactly as the official installer does.
2. **Audio crash (0xC0000409).** The mod captures game audio through `ActivateAudioInterfaceAsync("VAD\Process_Loopback")`, probably for haptics.
   - Wine rejects that device path, and the mod then fast-fails.
   - The fix changes one jump in Proton's `mmdevapi.dll` (6 bytes at offset `0x369E`), so the request falls through to the default playback device, where winepulse already supports loopback capture.
   - **Found and verified by [polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix).** Here it's applied only to a private Proton copy, and only after checking the surrounding bytes match.
3. **Old VC++ runtime.** The EA app installs `msvcp140.dll` 14.34 into the prefix. `Titanfall2VR.dll` is built with a newer MSVC, and against older runtimes its `std::mutex` use reads a null pointer: a crash in `MSVCP140.dll` right after the plugin loads. Runtime 14.40 or newer fixes it, which is what an up-to-date Windows PC would have.
4. **Proton's VR bridge.** Proton's `steam.exe` helper only writes the OpenXR/Vulkan data that `wineopenxr` needs (`HKCU\Software\Wine\VR`) for processes it thinks Steam started. The launcher sets `SteamGameId=1237970` so the bridge gets set up.
5. **EA app keeps the session alive.** `proton run` doesn't return while the EA app is open, and Steam keeps showing Titanfall 2 as running. The launcher follows `crash_monitor.exe` instead, reads the game's exit code from it, and then closes the EA app and the Wine session.

## Credits

- **[CircuitLord](https://github.com/CircuitLord/CircuitLordVRModInstaller)** for the Titanfall 2 VR mod and its installer (MIT). Everything here follows that installer.
- **[polar421](https://github.com/polar421/Titanfall-2-VR-linux-fix)** for getting the mod running on Proton first and finding the `mmdevapi.dll` audio fix.
- **[Northstar](https://github.com/R2Northstar/Northstar)**, the mod loader the VR mod runs on.

This is a community project. It isn't affiliated with or endorsed by Respawn, EA, Valve or CircuitLord.

## License

[MIT](LICENSE). You can use, copy, modify, share and sell it freely; just keep the license notice. The mod, Northstar and the game have their own licenses and aren't included here.
