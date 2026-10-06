#!/usr/bin/env bash
# Titanfall 2 VR (CircuitLord's TF2VR mod) on Linux / Proton.
#
#   ./install.sh                  set up Proton-TF2VR, install or update the mod, install the tf2vr launcher
#   ./install.sh --check          preflight checks only, change nothing
#   ./install.sh --force          reinstall the mod even if it is already up to date
#   ./install.sh --refresh-proton rebuild Proton-TF2VR from the newest compatible Proton build
#   ./install.sh --uninstall      remove the mod files, launcher and Proton-TF2VR (campaign saves are kept)
#
# Titanfall 2 from the EA app (Faugus, Heroic, Lutris, Bottles...) instead of Steam is found
# automatically, or point at it:
#   ./install.sh --game DIR       the folder with Titanfall2.exe
#   ./install.sh --prefix DIR     the Wine prefix the EA app is installed in
#   ./install.sh --proton-base DIR  build Proton-TF2VR from this Proton build
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

GE_NAME="GE-Proton11-1"
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_NAME/$GE_NAME.tar.gz"
GE_SHA="ce6dd663ea01725a31805ed5c165723a253cdf0945a6642907330742ae2de5e4"
STEAM_OFFER="Origin.OFR.50.0001456"
NO_STEAM_DIR="$STATE/no-steam"

RUN_CMD=tf2vr
MODE=install
FORCE=0
REFRESH_PROTON=0
OPT_GAME=""
OPT_PREFIX=""
OPT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)          MODE=check ;;
    --uninstall)      MODE=uninstall ;;
    --force)          FORCE=1 ;;
    --refresh-proton) REFRESH_PROTON=1 ;;
    --game|--prefix|--proton-base)
      [ $# -ge 2 ] || { echo "install.sh: $1 needs a folder" >&2; exit 2; }
      [ -d "$2" ] || { echo "install.sh: $1: '$2' isn't a folder" >&2; exit 2; }
      case "$1" in
        --game)        OPT_GAME=$(readlink -f "$2") ;;
        --prefix)      OPT_PREFIX=$(readlink -f "$2") ;;
        --proton-base) OPT_BASE=$(readlink -f "$2") ;;
      esac
      shift ;;
    -h|--help)        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
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
  for c in "${STEAM_DIR:-}" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
           "$HOME/.steam/debian-installation" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [ -n "$c" ] && [ -f "$c/steamapps/libraryfolders.vdf" ]; then readlink -f "$c"; return 0; fi
  done
  return 1
}

libraries() {
  [ -n "$STEAM" ] || return 0
  { printf '%s\n' "$STEAM"
    sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$STEAM/steamapps/libraryfolders.vdf"
  } | awk '!seen[$0]++'
}

compat_root() {
  if [ "$(basename "$1")" = pfx ] && [ -d "$1/drive_c" ]; then dirname "$1"; else printf '%s\n' "$1"; fi
}

prefix_registries() {
  local root lib
  for root in "$HOME/Faugus" "$HOME/Games" "${XDG_DATA_HOME:-$HOME/.local/share}/bottles/bottles" \
              "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles" "$HOME/.wine"; do
    [ -d "$root" ] && find "$root" -maxdepth 7 -type f -name system.reg 2>/dev/null
  done
  while IFS= read -r lib; do
    [ -d "$lib/steamapps/compatdata" ] && find "$lib/steamapps/compatdata" -mindepth 2 -maxdepth 3 -type f -name system.reg \
      -not -path "$lib/steamapps/compatdata/$APPID/*" 2>/dev/null
  done < <(libraries)
  [ -n "$OPT_PREFIX" ] && find "$OPT_PREFIX/" -maxdepth 2 -type f -name system.reg 2>/dev/null
  return 0
}

registry_installs() {
  python3 - "$@" <<'PY'
import os, re, sys

KEY = re.compile(r'^\[Software\\\\(?:Wow6432Node\\\\)?Respawn\\\\Titanfall2\][^\n]*\n(.*?)(?=^\[|\Z)', re.M | re.S | re.I)
VALUE = re.compile(r'^"Install Dir"="((?:[^"\\]|\\.)*)"', re.M | re.I)

def unescape(text):
    def one(m):
        t = m.group(1)
        if t[0] in 'xX' and len(t) > 1:
            return chr(int(t[1:], 16))
        return {'n': '\n', 't': '\t', '0': '\0'}.get(t, t)
    return re.sub(r'\\([xX][0-9a-fA-F]{1,4}|.)', one, text)

def nocase(path):
    if os.path.exists(path):
        return path
    cur = '/'
    for part in [x for x in path.split('/') if x]:
        nxt = os.path.join(cur, part)
        if not os.path.exists(nxt):
            try:
                match = [e for e in os.listdir(cur) if e.lower() == part.lower()]
            except OSError:
                return None
            if not match:
                return None
            nxt = os.path.join(cur, match[0])
        cur = nxt
    return cur

def to_linux(pfx, winpath):
    m = re.match(r'^([A-Za-z]):[\\/]*(.*)$', winpath)
    if not m:
        return None
    letter, rest = m.group(1).lower(), m.group(2).replace('\\', '/').strip('/')
    link = os.path.join(pfx, 'dosdevices', letter + ':')
    if os.path.lexists(link):
        base = os.path.realpath(link)
    elif letter == 'z':
        base = '/'
    else:
        return None
    return nocase(os.path.join(base, rest))

for reg in sys.argv[1:]:
    pfx = os.path.dirname(reg)
    compat = os.path.dirname(pfx) if os.path.basename(pfx) == 'pfx' else pfx
    compat = os.path.realpath(compat)
    if os.path.isdir(os.path.join(pfx, 'drive_c', 'Program Files', 'Electronic Arts', 'EA Desktop')):
        print(f'E\t{compat}')
    try:
        data = open(reg, 'rb').read()
    except OSError:
        continue
    if b'Respawn\\\\Titanfall2' not in data:
        continue
    for section in KEY.finditer(data.decode('utf-8', 'replace')):
        value = VALUE.search(section.group(1))
        if not value:
            continue
        game = to_linux(pfx, unescape(value.group(1)))
        if game and os.path.isdir(game) and any(e.lower() == 'titanfall2.exe' for e in os.listdir(game)):
            print(f'G\t{os.path.realpath(game)}\t{compat}')
PY
}

drive_c_installs() {
  local root lib exe game
  {
    for root in "$HOME/Faugus" "$HOME/Games" "${XDG_DATA_HOME:-$HOME/.local/share}/bottles/bottles" \
                "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles" "$HOME/.wine"; do
      [ -d "$root" ] && find "$root" -maxdepth 10 -type f -name Titanfall2.exe -path '*/drive_c/*' 2>/dev/null
    done
    while IFS= read -r lib; do
      [ -d "$lib/steamapps/compatdata" ] && find "$lib/steamapps/compatdata" -mindepth 1 -maxdepth 8 \
        -path "$lib/steamapps/compatdata/$APPID" -prune -o -type f -name Titanfall2.exe -path '*/drive_c/*' -print 2>/dev/null
    done < <(libraries)
    [ -n "$OPT_PREFIX" ] && find "$OPT_PREFIX/" -maxdepth 8 -type f -name Titanfall2.exe -path '*/drive_c/*' 2>/dev/null
  } | while IFS= read -r exe; do
    game=$(dirname "$exe")
    printf 'G\t%s\t%s\n' "$(readlink -f "$game")" "$(readlink -f "$(compat_root "${game%%/drive_c/*}")")"
  done
}

discover_ea() {
  local regs=() kind g c want
  local -a pairs=()
  [ -n "$OPT_GAME" ] && GAME=$OPT_GAME
  [ -n "$OPT_PREFIX" ] && PREFIX=$(compat_root "$OPT_PREFIX")
  mapfile -t regs < <(prefix_registries | awk '!seen[$0]++')
  while IFS=$'\t' read -r kind g c; do
    case "$kind" in
      G) pairs+=("$g"$'\t'"$c") ;;
      E) EA_PREFIXES+=("$g") ;;
    esac
  done < <({ [ "${#regs[@]}" -gt 0 ] && registry_installs "${regs[@]}"; drive_c_installs; } | awk '!seen[$0]++')
  if [ -n "$GAME" ] && [ -z "$PREFIX" ]; then
    want=$(readlink -f "$GAME")
    for g in "${pairs[@]}"; do
      [ "${g%%$'\t'*}" = "$want" ] && { PREFIX=${g#*$'\t'}; FOUND_VIA=" (its prefix found through the EA app's registry)"; break; }
    done
  elif [ -z "$GAME" ] && [ -n "$PREFIX" ]; then
    want=$(readlink -f "$PREFIX")
    for g in "${pairs[@]}"; do
      [ "${g#*$'\t'}" = "$want" ] && { EA_HITS+=("${g%%$'\t'*}"); }
    done
    [ "${#EA_HITS[@]}" = 1 ] && GAME=${EA_HITS[0]}
  elif [ -z "$GAME" ]; then
    for g in "${pairs[@]}"; do EA_HITS+=("${g%%$'\t'*}  (prefix: ${g#*$'\t'})"); done
    if [ "${#pairs[@]}" = 1 ]; then
      GAME=${pairs[0]%%$'\t'*} PREFIX=${pairs[0]#*$'\t'}
    fi
  fi
  if [ -n "$GAME" ] && [ -z "$PREFIX" ]; then
    case "$GAME" in */drive_c/*) PREFIX=$(compat_root "${GAME%%/drive_c/*}") ;; esac
  fi
  return 0
}

discover() {
  STEAM=$(find_steam) || STEAM=""
  GAME="" PREFIX="" EXPERIMENTAL="" GAME_SOURCE=steam EA_HITS=() EA_PREFIXES=() FOUND_VIA=""
  local lib
  while IFS= read -r lib; do
    if [ -z "$GAME" ] && [ -f "$lib/steamapps/common/Titanfall2/Titanfall2.exe" ]; then
      GAME="$lib/steamapps/common/Titanfall2"
      PREFIX="$lib/steamapps/compatdata/$APPID"
    fi
    if [ -z "$EXPERIMENTAL" ] && [ -x "$lib/steamapps/common/Proton - Experimental/proton" ]; then
      EXPERIMENTAL="$lib/steamapps/common/Proton - Experimental"
    fi
  done < <(libraries)
  if [ -n "$GAME" ] && [ ! -d "$PREFIX/pfx" ]; then
    while IFS= read -r lib; do
      [ -d "$lib/steamapps/compatdata/$APPID/pfx" ] && { PREFIX="$lib/steamapps/compatdata/$APPID"; break; }
    done < <(libraries)
  fi
  if [ -n "$OPT_GAME$OPT_PREFIX" ] || [ -z "$GAME" ]; then
    GAME_SOURCE=ea GAME="" PREFIX=""
    discover_ea
  fi
  PFX="$PREFIX"
  [ -n "$PREFIX" ] && [ -e "$PREFIX/pfx" ] && PFX="$PREFIX/pfx"
  TOOLS_DIR="${STEAM:-$HOME/.local/share/Steam}/compatibilitytools.d"
  TOOL="$TOOLS_DIR/$TOOL_NAME"
  PROTON="$TOOL/proton"
}

# The compat tool Steam is set to use for Titanfall 2, if any
steam_compat_tool() {
  [ -n "$STEAM" ] || return 0
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
# Proton runs outside Steam's runtime here, so these libraries come from the system.
# Skipped where there's no ldconfig cache to ask.
host_libs() {
  local lc missing=0 entry lib level why
  lc=$(command -v ldconfig || echo /sbin/ldconfig)
  [ -x "$lc" ] || return 0
  for entry in "libgnutls.so.30|fail|gnutls - the EA app needs it to sign in" \
               "libvulkan.so.1|fail|the Vulkan loader (Arch: vulkan-icd-loader) - DXVK and VR need it" \
               "libX11.so.6|fail|libx11 - Wine needs it to open windows" \
               "libpulse.so.0|warn|libpulse - the audio fix goes through Wine's PulseAudio driver"; do
    IFS='|' read -r lib level why <<<"$entry"
    "$lc" -p 2>/dev/null | awk -v l="$lib" '$1 == l && /x86-64/ { f = 1 } END { exit !f }' && continue
    "$level" "$lib isn't installed: install $why"
    missing=1
  done
  [ "$missing" = 1 ] || ok "system libraries Proton needs (gnutls, Vulkan, X11, PulseAudio)"
}

base_label() { awk '{ print $NF }' "$1/version" 2>/dev/null || basename "$1"; }

proton_candidates() {
  local d
  if [ -n "$OPT_BASE" ]; then printf '%s\n' "$OPT_BASE"; return; fi
  [ -n "$EXPERIMENTAL" ] && printf '%s\n' "$EXPERIMENTAL"
  for d in "$TOOLS_DIR" "$HOME/.local/share/Steam/compatibilitytools.d" "$HOME/.steam/root/compatibilitytools.d" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/heroic/tools/proton" \
           "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/umu/compatibilitytools" "$CACHE"; do
    [ -d "$d" ] && find -L "$d" -mindepth 2 -maxdepth 2 -type f -name proton -printf '%h\n' 2>/dev/null | sort -V -r
  done
}

pick_base() {
  BASE="" BASE_LABEL=""
  local d
  while IFS= read -r d; do
    [ -f "$d/$MMDEVAPI" ] && [ ! -f "$d/.tf2vr" ] || continue
    case "$d" in *.partial) continue ;; esac
    [ "$(mmdevapi check "$d/$MMDEVAPI")" = unpatched ] || continue
    BASE=$d BASE_LABEL=$(base_label "$d")
    return 0
  done < <(proton_candidates | awk '!seen[$0]++')
  return 1
}

# Proton is built for Steam's runtime, which brings its own glibc. Run outside it, as here, it uses
# the system's, and on an older one Wine's X11 driver and the OpenXR loader refuse to load.
glibc_check() {
  local dir need have
  if [ -f "$PROTON" ]; then dir=$TOOL; else dir=${BASE:-}; fi
  [ -n "$dir" ] && [ -f "$dir/files/lib/wine/x86_64-unix/winex11.so" ] || return 0
  need=$(grep -aoE 'GLIBC_2\.[0-9]+' "$dir/files/lib/wine/x86_64-unix/winex11.so" | sort -uV | tail -n 1 || true)
  need=${need#GLIBC_}
  have=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }' || true)
  [ -n "$need" ] && [ -n "$have" ] || return 0
  if [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n 1)" = "$need" ]; then
    ok "glibc $have (Proton needs $need)"
  else
    fail "glibc $have is too old: Proton $(cut -d' ' -f2 "$dir/version") needs $need or newer outside Steam (Ubuntu 22.04, Mint 21 and Pop!_OS 22.04 have 2.35, Debian 12 has 2.36). A newer distro release is needed, e.g. Ubuntu 24.04, Mint 22 or Debian 13."
  fi
}

ea_prefix_hint() {
  [ "${#EA_PREFIXES[@]}" -gt 0 ] || return 0
  echo "          Wine prefixes with the EA app installed:"
  printf '            %s\n' "${EA_PREFIXES[@]}"
}

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

  [ "$(uname -m)" = x86_64 ] || warn "This system is $(uname -m). These scripts run Proton's x86_64 Wine directly, which only works on x86_64 PCs (see \"Can I play on a Steam Frame or other ARM device?\" in the README)."
  host_libs

  if [ -n "${PULSE_SERVER:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
    ok "PulseAudio-compatible sound server running"
  else
    warn "No PulseAudio-compatible sound server is running; the audio fix needs one (with PipeWire, install pipewire-pulse)"
  fi
  if [ "$GAME_SOURCE" = steam ]; then
    ok "Steam: $STEAM"
    ok "Titanfall 2 (Steam): $GAME"
    if [ -d "$PREFIX/pfx" ]; then
      ok "Wine prefix: $PREFIX"
    else
      fail "No Wine prefix for Titanfall 2 yet - launch the game once from Steam (EA app sign-in) first"
    fi
  else
    if [ -n "$GAME" ]; then
      ok "Titanfall 2 (EA app): $GAME$FOUND_VIA"
    elif [ "${#EA_HITS[@]}" -gt 1 ]; then
      fail "Titanfall 2 is installed in more than one place - pick one with --game DIR --prefix DIR:"
      printf '          %s\n' "${EA_HITS[@]}"
    else
      fail "Titanfall 2 not found on Steam or in a Faugus, Heroic, Lutris, Bottles or non-Steam-game prefix - point at it: ./install.sh --game DIR --prefix DIR"
      ea_prefix_hint
    fi
    if [ -n "$PREFIX" ] && { [ -d "$PREFIX/pfx/drive_c" ] || [ -d "$PREFIX/drive_c" ]; }; then
      ok "Wine prefix: $PREFIX"
    elif [ -n "$PREFIX" ]; then
      fail "$PREFIX isn't a Wine prefix (no drive_c in it)"
    elif [ -n "$GAME" ]; then
      fail "Couldn't tell which Wine prefix $GAME belongs to - add --prefix DIR (the prefix the EA app is installed in)"
      ea_prefix_hint
    fi
  fi
  # "EA Desktop\EA Desktop" is a Wine reparse point Linux can't follow, so look in the versioned folders
  if [ -n "$PREFIX" ] && [ -n "$(find "$PFX/drive_c/Program Files/Electronic Arts/EA Desktop" -maxdepth 3 -name EADesktop.exe -print -quit 2>/dev/null)" ]; then
    ok "EA app installed in the prefix"
  elif [ -z "$PREFIX" ]; then
    :
  elif [ "$GAME_SOURCE" = steam ]; then
    warn "EA app not found in the prefix - launch Titanfall 2 once from Steam and sign in"
  else
    warn "EA app not found in the prefix - install it there with your launcher and sign in"
  fi

  if [ -f "$PROTON" ] && [ "$(mmdevapi check "$TOOL/$MMDEVAPI")" = patched ]; then
    ok "$TOOL_NAME ready ($(base_label "$TOOL"), audio fix applied)"
  elif pick_base; then
    ok "Proton to build $TOOL_NAME from: $BASE_LABEL ($BASE)"
  elif [ -n "$OPT_BASE" ]; then
    fail "The audio fix doesn't match $OPT_BASE ($(base_label "$OPT_BASE")); Proton Experimental and $GE_NAME are known to work"
  else
    ok "No compatible Proton installed - $GE_NAME (about 530 MB) will be downloaded to build $TOOL_NAME"
  fi
  if [ -n "$OPT_BASE" ] && [ "${BASE:-}" != "$OPT_BASE" ] && [ -f "$PROTON" ] && [ "$REFRESH_PROTON" = 0 ]; then
    warn "$TOOL_NAME already exists, so --proton-base is only used with --refresh-proton"
  fi
  glibc_check

  if [ "$GAME_SOURCE" = steam ]; then
    local tool
    tool=$(steam_compat_tool)
    [ "$tool" = "$TOOL_NAME" ] && ok "Steam runs Titanfall 2 with $TOOL_NAME" \
      || warn "Steam runs Titanfall 2 with '${tool:-default Proton}' - switch it to $TOOL_NAME after install (Properties -> Compatibility)"
  fi

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
download_ge() {
  mkdir -p "$CACHE"
  fetch "$GE_URL" "$GE_SHA" "$CACHE/$GE_NAME.tar.gz"
  rm -rf "$CACHE/$GE_NAME.unpack"
  mkdir -p "$CACHE/$GE_NAME.unpack"
  echo "  unpacking $GE_NAME..."
  tar -xzf "$CACHE/$GE_NAME.tar.gz" -C "$CACHE/$GE_NAME.unpack" || die "couldn't unpack $CACHE/$GE_NAME.tar.gz"
  [ -f "$CACHE/$GE_NAME.unpack/$GE_NAME/proton" ] || die "$GE_NAME.tar.gz doesn't contain $GE_NAME/proton"
  [ "$(mmdevapi check "$CACHE/$GE_NAME.unpack/$GE_NAME/$MMDEVAPI")" = unpatched ] \
    || die "the audio fix doesn't match the downloaded $GE_NAME"
  BASE="$CACHE/$GE_NAME.unpack/$GE_NAME" BASE_LABEL=$GE_NAME
}

setup_proton() {
  echo
  echo "$TOOL_NAME:"
  if [ "$REFRESH_PROTON" = 0 ] && [ -f "$PROTON" ] && [ "$(mmdevapi check "$TOOL/$MMDEVAPI")" = patched ]; then
    ok "already set up ($(base_label "$TOOL"))"
    return
  fi
  if ! pick_base; then
    [ -z "$OPT_BASE" ] || die "the audio fix doesn't match $OPT_BASE"
    download_ge
  fi
  [ -z "$OPT_BASE" ] || [ "$BASE" = "$OPT_BASE" ] || die "the audio fix doesn't match $OPT_BASE"

  if [ -e "$TOOL" ]; then
    [ -f "$TOOL/.tf2vr" ] || die "$TOOL exists and wasn't made by this script; move it away first"
    rm -rf "$TOOL"
  fi
  mkdir -p "$TOOLS_DIR"
  rm -rf "$TOOL.partial"
  case "$BASE" in
    "$CACHE/$GE_NAME.unpack/"*)
      mv "$BASE" "$TOOL.partial"
      rm -rf "$CACHE/$GE_NAME.unpack" ;;
    *)
      echo "  copying $BASE_LABEL (about 1.5 GB)..."
      cp -a --reflink=auto "$BASE" "$TOOL.partial" ;;
  esac
  rm -f "$TOOL.partial/dist.lock"
  touch "$TOOL.partial/.tf2vr"
  cat > "$TOOL.partial/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$TOOL_NAME"
    {
      "install_path" "."
      "display_name" "$TOOL_NAME ($BASE_LABEL + TF2VR audio fix)"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
VDF
  [ "$(mmdevapi apply "$TOOL.partial/$MMDEVAPI")" = patched ] || die "patching mmdevapi.dll failed"
  mv "$TOOL.partial" "$TOOL"
  ok "built $TOOL from $BASE_LABEL"
  ok "mmdevapi.dll patched (original kept as mmdevapi.dll.orig)"
  if [ "$GAME_SOURCE" = steam ]; then
    echo "  Restart Steam, then set Titanfall 2 -> Properties -> Compatibility -> $TOOL_NAME"
  else
    echo "  In your launcher (Faugus, Heroic, Lutris...), set the EA app's and Titanfall 2's Proton to $TOOL_NAME"
  fi
}

# --------------------------------------------------- VC++ runtime (prefix) --
VCREDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
VC_DLLS="concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids vcruntime140 vcruntime140_1"

# Version of the prefix's msvcp140.dll when it's Microsoft's own build, e.g. 14.44.35211.0.
# Empty when it's missing or Wine's built-in copy, which reports 14.42 but isn't Microsoft's runtime.
vc_version() {
  python3 - "$PFX/drive_c/windows/system32/msvcp140.dll" <<'PY' 2>/dev/null || true
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
  local sys32="$PFX/drive_c/windows/system32" version
  version=$(vc_version)
  if vc_new_enough "$version"; then
    ok "msvcp140.dll $version"
    return
  fi
  echo "  msvcp140.dll is ${version:-missing or the Wine built-in copy}; the mod needs Microsoft's 14.40 or newer."
  echo "  Installing the current VC++ redistributable into the Titanfall 2 prefix..."
  mkdir -p "$CACHE"
  curl -fL --progress-bar -o "$CACHE/vc_redist.x64.exe" "$VCREDIST_URL" || die "couldn't download $VCREDIST_URL"
  stop_prefix
  run_in_prefix waitforexitandrun "$CACHE/vc_redist.x64.exe" /install /quiet /norestart > "$CACHE/vc_redist.log" 2>&1 || true
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

compat_client_dir() {
  if [ "$GAME_SOURCE" = steam ]; then
    printf '%s\n' "$STEAM"
  else
    mkdir -p "$NO_STEAM_DIR"
    printf '%s\n' "$NO_STEAM_DIR"
  fi
}

run_in_prefix() {
  STEAM_COMPAT_CLIENT_INSTALL_PATH="$(compat_client_dir)" STEAM_COMPAT_DATA_PATH="$PREFIX" "$PROTON" "$@"
}

stop_prefix() {
  WINEPREFIX="$PFX" "$TOOL/files/bin/wineserver" -k 2>/dev/null || true
}

ensure_pfx_layout() {
  [ -e "$PREFIX/pfx" ] && { PFX="$PREFIX/pfx"; return; }
  [ -d "$PREFIX/drive_c" ] || die "$PREFIX isn't a Wine prefix (no drive_c in it)"
  ln -s . "$PREFIX/pfx"
  mkdir -p "$STATE"
  printf '%s\n' "$PREFIX" > "$STATE/pfx-link"
  PFX="$PREFIX/pfx"
  ok "linked $PREFIX/pfx to the prefix itself, the layout Proton expects (umu does the same)"
}

# Everything after this runs Windows programs through Proton-TF2VR directly (outside Steam), which
# needs Proton's x86_64 Wine to start on this machine.
check_wine_runs() {
  "$TOOL/files/bin/wine" --version >/dev/null 2>&1 && return 0
  die "Proton's Wine can't run directly on this system ($(uname -m)): $("$TOOL/files/bin/wine" --version 2>&1 | head -n 1)
These scripts start Proton outside Steam, which only works on x86_64 Linux PCs. Nothing has been
installed into the game yet. On a Steam Frame or other ARM headset, run the game on a PC and stream it
instead: see "Can I play on a Steam Frame or other ARM device?" in the README."
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
  [ -f "$PFX/system.reg" ] || die "no Wine prefix at $PREFIX - start Titanfall 2 once the normal way first"
  echo "  building game assets (first run also updates the Wine prefix, this can take a minute)..."
  run_in_prefix run "$WORK/mod/asset_patcher.exe" apply "$(win "$GAME")" "$(win "$WORK/mod/patches")" "$(win "$WORK/assets")" \
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
  install -Dm644 "$HERE/discord-presence.py" "$STATE/discord-presence.py"
  ok "$STATE/discord-presence.py (Discord status)"

  mkdir -p "$(dirname "$CONF")"
  {
    echo "# written by tf2vr-linux/install.sh"
    printf 'STEAM_ROOT=%q\nGAME_DIR=%q\nPREFIX_DIR=%q\nPROTON_BIN=%q\n' "$STEAM" "$GAME" "$PREFIX" "$PROTON"
    printf 'GAME_SOURCE=%q\nNO_STEAM_DIR=%q\n' "$GAME_SOURCE" "$NO_STEAM_DIR"
    if [ "$GAME_SOURCE" = steam ]; then printf 'CONTENT_ID=%q\n' "$STEAM_OFFER"; else echo "CONTENT_ID="; fi
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
    *) RUN_CMD="$BIN/tf2vr"
       warn "$BIN isn't on your PATH (Arch doesn't add it by default), so plain 'tf2vr' won't be found: run $RUN_CMD, or add $BIN to PATH" ;;
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
  local link
  link=$(cat "$STATE/pfx-link" 2>/dev/null || true)
  if [ -n "$link" ] && [ -L "$link/pfx" ] && [ "$(readlink "$link/pfx")" = . ]; then
    rm -f "$link/pfx"
    ok "removed the pfx link install.sh added to $link"
  fi
  rm -rf "$STATE" "$(dirname "$CONF")"
  rm -f "$BIN/tf2vr" "$APPS/tf2vr.desktop"
  ok "removed the launcher and app menu entry"
  if [ -f "$TOOL/.tf2vr" ]; then
    rm -rf "$TOOL"
    ok "removed $TOOL"
  fi
  if [ "$GAME_SOURCE" = steam ]; then
    [ "$(steam_compat_tool)" = "$TOOL_NAME" ] \
      && warn "Steam still runs Titanfall 2 with $TOOL_NAME - switch it back (Properties -> Compatibility) and restart Steam"
  else
    warn "If your launcher runs the EA app or Titanfall 2 with $TOOL_NAME, switch them to another Proton"
  fi
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
    fails_before=$fails
    glibc_check
    [ "$fails" = "$fails_before" ] || die "the system glibc is too old for $TOOL_NAME (see above)"
    if pgrep -f '[\\/](Titanfall2|Titanfall2VRLauncher|EADesktop)\.exe' >/dev/null; then
      die "Titanfall 2 or the EA app is running - close them first"
    fi
    check_wine_runs
    ensure_pfx_layout
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
  echo "Start your headset's OpenXR runtime (e.g. SteamVR), then run:  $RUN_CMD   (or 'Titanfall 2 VR' in your app menu)"
  if [ "$GAME_SOURCE" = steam ]; then
    echo "Steam's Play button keeps starting the normal, flat game."
  else
    echo "Set the EA app's and Titanfall 2's Proton to $TOOL_NAME in your launcher too, so both use the same Wine."
    echo "Starting the game from your launcher keeps starting the normal, flat game."
  fi
fi
exit 0
