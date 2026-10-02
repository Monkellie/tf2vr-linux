#!/usr/bin/env bash
# Titanfall 2 VR (CircuitLord's TF2VR mod) on Linux / Proton.
#
#   ./install.sh                  set up Proton-TF2VR, install or update the mod, install the tf2vr launcher
#   ./install.sh --check          preflight checks only, change nothing
#   ./install.sh --force          reinstall the mod even if it is already up to date
#   ./install.sh --refresh-proton rebuild Proton-TF2VR from the current Proton Experimental
#   ./install.sh --uninstall      remove the mod files, launcher and Proton-TF2VR (campaign saves are kept)
#
# Installs exactly what CircuitLordVRModInstaller.exe installs on Windows (same downloads,
# same checksums, same file layout), plus the Proton audio fix and the newer VC++ runtime the
# mod needs on Linux.
# Set STEAM_DIR=/path/to/Steam if Steam isn't found automatically.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REPO_RAW="https://raw.githubusercontent.com/CircuitLord/CircuitLordVRModInstaller"
MANIFEST_URL="$REPO_RAW/main/manifest-v3.json"
APPID=1237970
TOOL_NAME="Proton-TF2VR"
MMDEVAPI="files/lib/wine/x86_64-windows/mmdevapi.dll"

BIN="$HOME/.local/bin"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/tf2vr"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tf2vr/paths.env"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tf2vr"

MODE=install
FORCE=0
REFRESH_PROTON=0
for a in "$@"; do
  case "$a" in
    --check)          MODE=check ;;
    --uninstall)      MODE=uninstall ;;
    --force)          FORCE=1 ;;
    --refresh-proton) REFRESH_PROTON=1 ;;
    -h|--help)        sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$a' (try --help)" >&2; exit 2 ;;
  esac
done

fails=0
warns=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# Windows path of a Linux path, as Wine sees it through drive Z:
win() { local p; p=$(readlink -f "$1"); printf 'Z:%s' "${p//\//\\}"; }

# ------------------------------------------------------------ discovery --
find_steam() {
  local c
  for c in "${STEAM_DIR:-}" "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [ -n "$c" ] && [ -f "$c/steamapps/libraryfolders.vdf" ]; then readlink -f "$c"; return 0; fi
  done
  return 1
}

libraries() {
  printf '%s\n' "$STEAM"
  sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$STEAM/steamapps/libraryfolders.vdf"
}

discover() {
  STEAM=$(find_steam) || STEAM=""
  GAME="" PREFIX="" EXPERIMENTAL=""
  [ -n "$STEAM" ] || return 0
  local lib
  while IFS= read -r lib; do
    if [ -z "$GAME" ] && [ -f "$lib/steamapps/common/Titanfall2/Titanfall2.exe" ]; then
      GAME="$lib/steamapps/common/Titanfall2"
      PREFIX="$lib/steamapps/compatdata/$APPID"
    fi
    if [ -z "$EXPERIMENTAL" ] && [ -x "$lib/steamapps/common/Proton - Experimental/proton" ]; then
      EXPERIMENTAL="$lib/steamapps/common/Proton - Experimental"
    fi
  done < <(libraries | awk '!seen[$0]++')
  TOOL="$STEAM/compatibilitytools.d/$TOOL_NAME"
  PROTON="$TOOL/proton"
}

# The compat tool Steam is set to use for Titanfall 2, if any
steam_compat_tool() {
  python3 - "$STEAM/config/config.vdf" "$APPID" <<'PY' 2>/dev/null || true
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
block = text[text.find('"CompatToolMapping"'):]
m = re.search(r'"%s"\s*\{\s*"name"\s*"([^"]*)"' % sys.argv[2], block)
print(m.group(1) if m else "")
PY
}

# ------------------------------------------------------ mmdevapi patch --
# Under Wine, ActivateAudioInterfaceAsync() rejects the VAD\Process_Loopback device the mod
# opens, and the mod then fast-fails with 0xC0000409. This retargets the one `je` taken for
# unknown device paths so it falls through to the default render endpoint, where winepulse
# already supports loopback capture. Found and verified by polar421:
# https://github.com/polar421/Titanfall-2-VR-linux-fix
# Prints patched / unpatched / unknown. "apply" patches an unpatched file and keeps a .orig copy.
mmdevapi() {
  python3 - "$1" "$2" <<'PY'
import os, shutil, stat, sys
mode, path = sys.argv[1], sys.argv[2]
OFF = 0x369E
CONTEXT = bytes.fromhex("0fb605e33b01004c8d3ddc3b0100a8010f859c010000a804")
ORIGINAL = bytes.fromhex("0f8471ffffff")  # je -> hr = 0x80070002
PATCHED = bytes.fromhex("0f843efdffff")   # je -> default render endpoint
data = open(path, "rb").read()
current = data[OFF:OFF + 6]
if data[OFF - len(CONTEXT):OFF] != CONTEXT or current not in (ORIGINAL, PATCHED):
    print("unknown"); sys.exit(0)
if current == PATCHED:
    print("patched"); sys.exit(0)
if mode != "apply":
    print("unpatched"); sys.exit(0)
shutil.copy2(path, path + ".orig")
mode_bits = os.stat(path).st_mode  # Proton ships its files read-only
os.chmod(path, mode_bits | stat.S_IWUSR)
with open(path, "r+b") as fh:
    fh.seek(OFF)
    fh.write(PATCHED)
os.chmod(path, mode_bits)
print("patched")
PY
}

# ------------------------------------------------------------ preflight --
preflight() {
  echo "Preflight:"
  local t
  for t in curl unzip sha256sum python3; do
    command -v "$t" >/dev/null 2>&1 && ok "$t available" || fail "$t is not installed"
  done
  if command -v cabextract >/dev/null 2>&1; then ok "cabextract available"
  elif command -v bsdtar >/dev/null 2>&1; then ok "bsdtar available"
  else warn "neither cabextract nor bsdtar is installed - only needed if the VC++ runtime installer fails under Wine"
  fi

  [ "$(uname -m)" = x86_64 ] || warn "This system is $(uname -m). These scripts run Proton's x86_64 Wine directly, which only works on x86_64 PCs (see \"Steam Frame and other ARM devices\" in the README)."
  if [ -z "$STEAM" ]; then
    fail "Steam not found (set STEAM_DIR=/path/to/Steam)"
    return
  fi
  ok "Steam: $STEAM"

  [ -n "$GAME" ] && ok "Titanfall 2: $GAME" \
    || fail "Titanfall 2 not found in any Steam library - install it from Steam first"
  if [ -n "$PREFIX" ] && [ -d "$PREFIX/pfx" ]; then
    ok "Wine prefix: $PREFIX"
  else
    fail "No Wine prefix for Titanfall 2 yet - launch the game once from Steam (EA app sign-in) first"
  fi
  # "EA Desktop\EA Desktop" is a Wine reparse point Linux can't follow, so look in the versioned folders
  if [ -n "$PREFIX" ] && [ -n "$(find "$PREFIX/pfx/drive_c/Program Files/Electronic Arts/EA Desktop" -maxdepth 3 -name EADesktop.exe -print -quit 2>/dev/null)" ]; then
    ok "EA app installed in the prefix"
  else
    warn "EA app not found in the prefix - launch Titanfall 2 once from Steam and sign in"
  fi

  if [ -f "$PROTON" ] && [ "$(mmdevapi check "$TOOL/$MMDEVAPI")" = patched ]; then
    ok "$TOOL_NAME ready (audio fix applied)"
  elif [ -n "$EXPERIMENTAL" ]; then
    case "$(mmdevapi check "$EXPERIMENTAL/$MMDEVAPI")" in
      unpatched) ok "Proton Experimental: $EXPERIMENTAL ($(cut -d' ' -f2 "$EXPERIMENTAL/version"))" ;;
      *) fail "This Proton Experimental build has a different mmdevapi.dll than the audio fix expects ($(cut -d' ' -f2 "$EXPERIMENTAL/version"))" ;;
    esac
  else
    fail "Proton Experimental not installed (Steam -> Library -> search 'Proton Experimental' -> Install)"
  fi

  local tool
  tool=$(steam_compat_tool)
  [ "$tool" = "$TOOL_NAME" ] && ok "Steam runs Titanfall 2 with $TOOL_NAME" \
    || warn "Steam runs Titanfall 2 with '${tool:-default Proton}' - switch it to $TOOL_NAME after install (Properties -> Compatibility)"

  local rt="${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json"
  [ -f "$rt" ] || rt=/etc/xdg/openxr/1/active_runtime.json
  if [ -f "$rt" ]; then
    ok "OpenXR runtime: $(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runtime"]; print(r.get("name") or r["library_path"])' "$rt" 2>/dev/null || echo "$rt")"
  else
    warn "No active OpenXR runtime - in SteamVR: Settings -> OpenXR -> Set SteamVR as OpenXR runtime"
  fi

  if [ -f "$STATE/version" ]; then ok "Installed: $(cat "$STATE/version")"; else ok "Mod not installed yet"; fi
}

# ------------------------------------------------------- Proton-TF2VR --
setup_proton() {
  echo
  echo "$TOOL_NAME:"
  if [ "$REFRESH_PROTON" = 0 ] && [ -f "$PROTON" ] && [ "$(mmdevapi check "$TOOL/$MMDEVAPI")" = patched ]; then
    ok "already set up ($(cut -d' ' -f2 "$TOOL/version"))"
    return
  fi
  [ -n "$EXPERIMENTAL" ] || die "Proton Experimental is not installed"
  [ "$(mmdevapi check "$EXPERIMENTAL/$MMDEVAPI")" = unpatched ] \
    || die "Proton Experimental's mmdevapi.dll doesn't match the audio fix; it can't be applied to this build"

  if [ -e "$TOOL" ]; then
    [ -f "$TOOL/.tf2vr" ] || die "$TOOL exists and wasn't made by this script; move it away first"
    rm -rf "$TOOL"
  fi
  mkdir -p "$STEAM/compatibilitytools.d"
  rm -rf "$TOOL.partial"
  echo "  copying Proton Experimental (about 1.5 GB)..."
  cp -a "$EXPERIMENTAL" "$TOOL.partial"
  rm -f "$TOOL.partial/dist.lock"
  touch "$TOOL.partial/.tf2vr"
  local version
  version=$(cut -d' ' -f2 "$TOOL.partial/version")
  cat > "$TOOL.partial/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$TOOL_NAME"
    {
      "install_path" "."
      "display_name" "$TOOL_NAME ($version + TF2VR audio fix)"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
VDF
  [ "$(mmdevapi apply "$TOOL.partial/$MMDEVAPI")" = patched ] || die "patching mmdevapi.dll failed"
  mv "$TOOL.partial" "$TOOL"
  ok "copied Proton Experimental $version to $TOOL"
  ok "mmdevapi.dll patched (original kept as mmdevapi.dll.orig)"
  echo "  Restart Steam, then set Titanfall 2 -> Properties -> Compatibility -> $TOOL_NAME"
}

# --------------------------------------------------- VC++ runtime (prefix) --
VCREDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VC_DLLS="concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids vcruntime140 vcruntime140_1"

# Version of the prefix's msvcp140.dll when it's Microsoft's own build, e.g. 14.44.35211.0.
# Empty when it's missing or Wine's built-in copy, which reports 14.42 but isn't Microsoft's runtime.
vc_version() {
  python3 - "$PREFIX/pfx/drive_c/windows/system32/msvcp140.dll" <<'PY' 2>/dev/null || true
import struct, sys
data = open(sys.argv[1], "rb").read()
i = data.find("VS_VERSION_INFO".encode("utf-16-le"))
j = data.find(b"\xbd\x04\xef\xfe", i) if i >= 0 else -1
if j >= 0 and b"Wine builtin DLL" not in data[:0x100]:
    ms, ls = struct.unpack_from("<II", data, j + 8)
    print(f"{ms >> 16}.{ms & 0xffff}.{ls >> 16}.{ls & 0xffff}")
PY
}

vc_new_enough() { [ -n "$1" ] && [ "$(printf '%s\n14.40\n' "$1" | sort -V | head -n 1)" = "14.40" ]; }

# extract_vc_dlls <vc_redist.x64.exe> <dir>: unpack the x64 runtime (*.dll_amd64) the way winetricks
# does. It's the a12 cabinet inside the bundle. cabextract finds it directly; bsdtar (part of
# libarchive, present on SteamOS) only reads the first cabinet, so cut each one out first.
extract_vc_dlls() {
  local exe=$1 out=$2 cab
  if command -v cabextract >/dev/null 2>&1; then
    cabextract -q -d "$out" -F a12 "$exe" 2>/dev/null && cabextract -q -d "$out" "$out/a12" 2>/dev/null && return 0
  fi
  command -v bsdtar >/dev/null 2>&1 || return 1
  python3 - "$exe" "$out" <<'PY' || return 1
import os, struct, sys
data, out, i, n = open(sys.argv[1], "rb").read(), sys.argv[2], 0, 0
while (i := data.find(b"MSCF\0\0\0\0", i)) >= 0:
    size = struct.unpack_from("<I", data, i + 8)[0]
    if 0 < size <= len(data) - i:
        open(os.path.join(out, f"bundle{n}.cab"), "wb").write(data[i:i + size])
        n, i = n + 1, i + size
    else:
        i += 4
PY
  for cab in "$out"/bundle*.cab; do
    bsdtar -xf "$cab" -C "$out" a12 2>/dev/null && break
  done
  [ -f "$out/a12" ] && bsdtar -xf "$out/a12" -C "$out" 2>/dev/null
}

# Titanfall2VR.dll is built with a recent MSVC and crashes (null read in MSVCP140.dll right
# after the plugin loads) against the 14.3x runtime the EA app installs into the prefix.
# Install the current VC++ 2015-2022 x64 redistributable, as a Windows PC would have.
ensure_vcredist() {
  echo
  echo "VC++ runtime in the prefix:"
  local sys32="$PREFIX/pfx/drive_c/windows/system32" version
  version=$(vc_version)
  if vc_new_enough "$version"; then
    ok "msvcp140.dll $version"
    return
  fi
  echo "  msvcp140.dll is ${version:-missing or the Wine built-in copy}; the mod needs Microsoft's 14.40 or newer."
  echo "  Installing the current VC++ redistributable into the Titanfall 2 prefix..."
  mkdir -p "$CACHE"
  curl -fL --progress-bar -o "$CACHE/vc_redist.x64.exe" "$VCREDIST_URL" || die "couldn't download $VCREDIST_URL"
  WINEPREFIX="$PREFIX/pfx" "$TOOL/files/bin/wineserver" -k 2>/dev/null || true
  STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" STEAM_COMPAT_DATA_PATH="$PREFIX" \
    "$PROTON" waitforexitandrun "$CACHE/vc_redist.x64.exe" /install /quiet /norestart > "$CACHE/vc_redist.log" 2>&1 || true
  version=$(vc_version)

  # Microsoft's installer sometimes finishes without changing anything under Wine. Copy the
  # DLLs out of it instead, the way winetricks does: the x64 runtime is the a12 cabinet inside.
  if ! vc_new_enough "$version"; then
    echo "  The installer didn't update it; copying the DLLs out of the redistributable instead..."
    local tmp dll
    tmp=$(mktemp -d "$CACHE/vcredist.XXXXXX")
    extract_vc_dlls "$CACHE/vc_redist.x64.exe" "$tmp" || true
    for dll in $VC_DLLS; do
      [ -f "$tmp/$dll.dll_amd64" ] || continue
      rm -f "$sys32/$dll.dll"   # may be a link to Proton's own copy; never write through it
      cp "$tmp/$dll.dll_amd64" "$sys32/$dll.dll"
    done
    rm -rf "$tmp"
    version=$(vc_version)
  fi

  if ! vc_new_enough "$version"; then
    echo "  Last lines of the redistributable's output ($CACHE/vc_redist.log):" >&2
    tail -n 8 "$CACHE/vc_redist.log" 2>/dev/null | sed 's/^/    /' >&2
    die "couldn't install the VC++ runtime (msvcp140.dll is ${version:-missing or the Wine built-in copy}).
Nothing has been installed into the game yet. Install cabextract or bsdtar (libarchive) and run
./install.sh again, or install the runtime with: protontricks $APPID vcrun2022"
  fi
  ok "msvcp140.dll $version"
}

# Everything after this runs Windows programs through Proton-TF2VR directly (outside Steam), which
# needs Proton's x86_64 Wine to start on this machine.
check_wine_runs() {
  "$TOOL/files/bin/wine" --version >/dev/null 2>&1 && return 0
  die "Proton's Wine can't run directly on this system ($(uname -m)): $("$TOOL/files/bin/wine" --version 2>&1 | head -n 1)
These scripts start Proton outside Steam, which only works on x86_64 Linux PCs. Nothing has been
installed into the game yet. On a Steam Frame or other ARM headset, run the game on a PC and stream it
instead: see "Steam Frame and other ARM devices" in the README."
}

# ------------------------------------------------------------ the mod --
# fetch <url> <sha256> <file>: download into the cache unless a verified copy is already there
fetch() {
  local url=$1 sha=$2 out=$3
  if [ -f "$out" ] && [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$sha" ]; then
    ok "cached $(basename "$out")"
    return
  fi
  echo "  downloading $(basename "$out")..."
  curl -fL --progress-bar -o "$out.part" "$url"
  [ "$(sha256sum "$out.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$out.part"; die "checksum mismatch for $url"; }
  mv "$out.part" "$out"
  ok "downloaded and verified $(basename "$out")"
}

core_files_present() {
  local f
  for f in Titanfall2VRLauncher.exe TF2VR/Northstar.dll TF2VR/plugins/Titanfall2VR.dll \
           TF2VR/tools/xr_probe.exe TF2VR/tools/crash_monitor.exe TF2VR/tools/launch.json; do
    [ -f "$GAME/$f" ] || return 1
  done
}

# place <source file> <path relative to the game folder>
place() {
  mkdir -p "$(dirname "$GAME/$2")"
  cp -f "$1" "$GAME/$2"
  printf '%s\n' "$2" >> "$WORK/files.txt"
}

# place_tree <source dir> <destination prefix relative to the game folder>
place_tree() {
  local f
  while IFS= read -r -d '' f; do
    place "$f" "$2/${f#"$1"/}"
  done < <(find "$1" -type f -print0 | sort -z)
}

install_mod() {
  echo
  echo "Titanfall 2 VR mod:"
  local manifest mod_version mod_url mod_sha commit source ns_version ns_url ns_sha
  manifest=$(curl -fsSL "$MANIFEST_URL?t=$(date +%s)") || die "couldn't download $MANIFEST_URL"
  read -r mod_version mod_url mod_sha commit < <(python3 -c '
import json, sys
m = json.load(sys.stdin)
t = m["titanfall2vr"]
print(t["version"], t["url"], t["sha256"], m["installer"]["commit"])' <<<"$manifest")
  [ -n "${commit:-}" ] || die "couldn't read the Titanfall 2 VR entry from $MANIFEST_URL"

  # Northstar is pinned in the official installer's source, read it from the same release
  source=$(curl -fsSL "$REPO_RAW/$commit/src/Installer/Installers/Titanfall2Installer.cs") \
    || die "couldn't read the official installer's Northstar pin"
  ns_version=$(sed -n 's/.*NorthstarVersion = "\([^"]*\)".*/\1/p' <<<"$source")
  ns_url=$(sed -n 's/.*NorthstarUrl = "\([^"]*\)".*/\1/p' <<<"$source")
  ns_sha=$(sed -n 's/.*NorthstarSha256 = "\([^"]*\)".*/\1/p' <<<"$source")
  [ -n "$ns_version" ] && [ -n "$ns_url" ] && [ -n "$ns_sha" ] || die "couldn't find the Northstar pin in Titanfall2Installer.cs"

  local wanted="mod=$mod_version northstar=$ns_version"
  if [ "$FORCE" = 0 ] && [ "$(cat "$STATE/version" 2>/dev/null)" = "$wanted" ] && core_files_present; then
    ok "up to date ($wanted)"
    return
  fi
  echo "  installing $wanted"

  mkdir -p "$CACHE" "$STATE"
  local mod_zip="$CACHE/Titanfall2VR-$mod_version.zip" ns_zip="$CACHE/Northstar-$ns_version.zip"
  fetch "$mod_url" "$mod_sha" "$mod_zip"
  fetch "$ns_url" "$ns_sha" "$ns_zip"

  WORK=$(mktemp -d "$CACHE/work.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  unzip -q "$mod_zip" -d "$WORK/mod"
  unzip -q "$ns_zip" NorthstarLauncher.exe 'R2Northstar/*' -d "$WORK/ns"
  local f
  for f in mod/Titanfall2VR.dll mod/xr_probe.exe mod/crash_monitor.exe mod/launch.json mod/release.json \
           mod/asset_patcher.exe mod/patches/manifest.json ns/NorthstarLauncher.exe ns/R2Northstar/Northstar.dll; do
    [ -f "$WORK/$f" ] || die "download is missing $f"
  done

  # Game-derived files ship as patches; asset_patcher.exe builds them from the installed game.
  # Run it before anything in the game folder changes, like the official installer does.
  [ -f "$PROTON" ] || die "$TOOL_NAME is missing"
  [ -f "$PREFIX/pfx/system.reg" ] || die "no Wine prefix at $PREFIX - launch Titanfall 2 from Steam once first"
  echo "  building game assets (first run also updates the Wine prefix, this can take a minute)..."
  STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" STEAM_COMPAT_DATA_PATH="$PREFIX" \
    "$PROTON" run "$WORK/mod/asset_patcher.exe" apply "$(win "$GAME")" "$(win "$WORK/mod/patches")" "$(win "$WORK/assets")" \
    > "$WORK/patcher.log" 2>&1 || true
  python3 - "$WORK/mod/patches/manifest.json" "$WORK/assets" <<'PY' || { tail -n 20 "$WORK/patcher.log" >&2; die "asset_patcher.exe didn't build the game assets (log above)"; }
import hashlib, json, os, sys
outputs = json.load(open(sys.argv[1]))["outputs"]
bad = [rel for rel, sha in outputs.items()
       if not os.path.isfile(os.path.join(sys.argv[2], rel))
       or hashlib.sha256(open(os.path.join(sys.argv[2], rel), "rb").read()).hexdigest() != sha]
if bad:
    print(f"{len(bad)} of {len(outputs)} built files are missing or wrong, e.g. {bad[0]}", file=sys.stderr)
    sys.exit(1)
PY
  ok "game assets built and verified"

  # Same layout as Titanfall2Installer.Install(); the vanilla Titanfall2.exe is never touched
  : > "$WORK/files.txt"
  place "$WORK/ns/NorthstarLauncher.exe" Titanfall2VRLauncher.exe
  place_tree "$WORK/ns/R2Northstar" TF2VR
  place "$WORK/mod/Titanfall2VR.dll" TF2VR/plugins/Titanfall2VR.dll
  place "$WORK/mod/xr_probe.exe" TF2VR/tools/xr_probe.exe
  place "$WORK/mod/crash_monitor.exe" TF2VR/tools/crash_monitor.exe
  place "$WORK/mod/launch.json" TF2VR/tools/launch.json
  place_tree "$WORK/mod/mods" TF2VR/mods
  place_tree "$WORK/assets" TF2VR
  sort -u "$WORK/files.txt" -o "$WORK/files.txt"

  # Files the previous version installed that this one doesn't
  if [ -f "$STATE/files.txt" ]; then
    local stale=0
    while IFS= read -r f; do
      case "$f" in ''|/*|*..*) continue ;; esac
      rm -f "$GAME/$f"
      rmdir -p --ignore-fail-on-non-empty "$(dirname "$GAME/$f")" 2>/dev/null || true
      stale=$((stale + 1))
    done < <(comm -23 "$STATE/files.txt" "$WORK/files.txt")
    [ "$stale" = 0 ] || ok "removed $stale file(s) the previous version used"
  fi

  cp "$WORK/files.txt" "$STATE/files.txt"
  printf '%s\n' "$wanted" > "$STATE/version"
  ok "installed $(wc -l < "$STATE/files.txt") files into $GAME"
}

# ------------------------------------------------------------ launcher --
install_launcher() {
  echo
  echo "Launcher:"
  install -Dm755 "$HERE/tf2vr" "$BIN/tf2vr"
  ok "$BIN/tf2vr"

  mkdir -p "$(dirname "$CONF")"
  {
    echo "# written by tf2vr-linux/install.sh"
    printf 'STEAM_ROOT=%q\nGAME_DIR=%q\nPREFIX_DIR=%q\nPROTON_BIN=%q\n' "$STEAM" "$GAME" "$PREFIX" "$PROTON"
  } > "$CONF"
  ok "$CONF"

  local icon=applications-games
  [ -n "$(find "${XDG_DATA_HOME:-$HOME/.local/share}/icons" -name "steam_icon_$APPID.png" -print -quit 2>/dev/null)" ] && icon="steam_icon_$APPID"
  mkdir -p "$APPS"
  sed -e "s|@BIN@|$BIN/tf2vr|" -e "s|@ICON@|$icon|" "$HERE/tf2vr.desktop" > "$APPS/tf2vr.desktop"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
  ok "app menu entry 'Titanfall 2 VR'"

  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) warn "$BIN is not on your PATH - run it as $BIN/tf2vr or add it to PATH" ;;
  esac
}

# ----------------------------------------------------------- uninstall --
uninstall() {
  echo
  echo "Uninstalling:"
  if [ -f "$STATE/files.txt" ] && [ -n "$GAME" ]; then
    local f n=0
    while IFS= read -r f; do
      case "$f" in ''|/*|*..*) continue ;; esac
      rm -f "$GAME/$f"
      rmdir -p --ignore-fail-on-non-empty "$(dirname "$GAME/$f")" 2>/dev/null || true
      n=$((n + 1))
    done < "$STATE/files.txt"
    ok "removed $n mod files from $GAME"
  fi
  rm -rf "$STATE" "$(dirname "$CONF")"
  rm -f "$BIN/tf2vr" "$APPS/tf2vr.desktop"
  ok "removed the launcher and app menu entry"
  if [ -f "$TOOL/.tf2vr" ]; then
    rm -rf "$TOOL"
    ok "removed $TOOL"
  fi
  [ "$(steam_compat_tool)" = "$TOOL_NAME" ] \
    && warn "Steam still runs Titanfall 2 with $TOOL_NAME - switch it back (Properties -> Compatibility) and restart Steam"
  echo "  Kept: campaign saves (in the Wine prefix) and Northstar logs under $GAME/TF2VR"
}

# ---------------------------------------------------------------- main --
discover
preflight

case "$MODE" in
  check) ;;
  uninstall) uninstall ;;
  install)
    [ "$fails" = 0 ] || die "fix the failed checks above first"
    setup_proton
    if pgrep -f '[\\/](Titanfall2|Titanfall2VRLauncher|EADesktop)\.exe' >/dev/null; then
      die "Titanfall 2 or the EA app is running - close them first"
    fi
    check_wine_runs
    ensure_vcredist
    install_mod
    install_launcher
    ;;
esac

echo
if [ "$fails" -gt 0 ]; then
  echo "Done with $fails failure(s) and $warns warning(s)."
  exit 1
fi
echo "Done ($warns warning(s))."
if [ "$MODE" = install ]; then
  echo "Start your headset's OpenXR runtime (e.g. SteamVR), then run:  tf2vr   (or 'Titanfall 2 VR' in your app menu)"
  echo "Steam's Play button keeps starting the normal, flat game."
fi
exit 0
