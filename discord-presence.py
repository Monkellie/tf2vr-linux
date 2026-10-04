import glob
import json
import os
import re
import select
import socket
import struct
import sys
import time
import uuid

CLIENT_ID = "363411468441354240"
NAME = "Titanfall 2 VR"

CHAPTERS = {
    "sp_training": "The Pilot's Gauntlet",
    "sp_crashsite": "BT-7274",
    "sp_sewers1": "Blood and Rust",
    "sp_boomtown_start": "Into the Abyss",
    "sp_boomtown": "Into the Abyss",
    "sp_boomtown_end": "Into the Abyss",
    "sp_hub_timeshift": "Effect and Cause",
    "sp_timeshift_spoke02": "Effect and Cause",
    "sp_beacon": "The Beacon",
    "sp_beacon_spoke0": "The Beacon",
    "sp_tday": "Trial by Fire",
    "sp_s2s": "The Ark",
    "sp_skyway_v1": "The Fold Weapon",
}
DIFFICULTIES = {"easy": "Easy", "normal": "Regular", "hard": "Hard", "master": "Master"}

LOADING = re.compile(r"UICodeCallback_LevelLoadingStarted: ?(\S*)")
LEVEL = re.compile(r"UICodeCallback_LevelInit: (\S+)")
MENU = re.compile(r"UICodeCallback_ActivateMenus: (menu_MainMenu|null)\s*$")
DIFFICULTY = re.compile(r"SP_Difficulty is: (\w+)")

IPC_ERRORS = (OSError, ValueError, struct.error)


def socket_paths():
    run = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    bases = [
        run,
        f"{run}/app/com.discordapp.Discord",
        f"{run}/app/com.discordapp.DiscordCanary",
        f"{run}/snap.discord",
        f"{run}/.flatpak/dev.vencord.Vesktop/xdg-run",
        f"{run}/app/dev.vencord.Vesktop",
        os.environ.get("TMPDIR") or "/tmp",
        "/tmp",
    ]
    seen = set()
    for base in bases:
        for i in range(10):
            path = f"{base}/discord-ipc-{i}"
            if path not in seen and os.path.exists(path):
                seen.add(path)
                yield path


class Discord:
    def __init__(self):
        self.sock = None
        self.last_error = None

    def close(self):
        if self.sock is not None:
            self.sock.close()
        self.sock = None

    def send(self, op, payload):
        data = json.dumps(payload).encode()
        self.sock.sendall(struct.pack("<II", op, len(data)) + data)

    def read_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Discord closed the connection")
            buf += chunk
        return buf

    def recv(self):
        op, n = struct.unpack("<II", self.read_exact(8))
        return op, json.loads(self.read_exact(n) or b"{}")

    def report(self, message):
        if message != self.last_error:
            print(f"Discord: {message}", flush=True)
            self.last_error = message

    def connect(self):
        for path in socket_paths():
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            try:
                sock.connect(path)
            except OSError:
                sock.close()
                continue
            self.sock = sock
            try:
                self.send(0, {"v": 1, "client_id": CLIENT_ID})
                op, msg = self.recv()
            except IPC_ERRORS:
                self.close()
                continue
            if op == 1 and msg.get("evt") == "READY":
                return True
            self.report(f"{path} refused the connection: {msg.get('message', msg)}")
            self.close()
        return False

    def set_activity(self, activity):
        self.send(1, {
            "cmd": "SET_ACTIVITY",
            "args": {"pid": os.getpid(), "activity": activity},
            "nonce": str(uuid.uuid4()),
        })

    def pump(self, timeout):
        end = time.monotonic() + timeout
        while (left := end - time.monotonic()) > 0:
            if not select.select([self.sock], [], [], left)[0]:
                return
            op, msg = self.recv()
            if op == 3:
                self.send(4, msg)
            elif op == 2:
                raise ConnectionError(msg.get("message", "Discord closed the connection"))
            elif op == 1 and msg.get("evt") == "ERROR":
                self.report(f"activity rejected: {msg.get('data', {}).get('message', msg)}")


class Game:
    def __init__(self, logs_dir, since):
        self.logs_dir = logs_dir
        self.since = since
        self.path = None
        self.pos = 0
        self.partial = b""
        self.chapter = None
        self.loading = False
        self.menu = False
        self.difficulty = None

    def find_log(self):
        logs = []
        for path in glob.glob(os.path.join(self.logs_dir, "nslog*.txt")):
            try:
                if os.path.getmtime(path) >= self.since:
                    logs.append(path)
            except OSError:
                pass
        return max(logs) if logs else None

    def poll(self):
        path = self.find_log()
        if path is None:
            return
        if path != self.path:
            self.path, self.pos, self.partial = path, 0, b""
        try:
            with open(path, "rb") as f:
                f.seek(self.pos)
                data = f.read()
                self.pos = f.tell()
        except OSError:
            return
        *lines, self.partial = (self.partial + data).split(b"\n")
        for line in lines:
            self.feed(line.decode("utf-8", "replace").rstrip("\r"))

    def feed(self, line):
        if m := LOADING.search(line):
            if m.group(1):
                self.chapter = CHAPTERS.get(m.group(1), "Campaign")
            self.loading, self.menu = True, False
        elif m := LEVEL.search(line):
            self.loading = False
            self.menu = m.group(1) == "mp_lobby"
            self.chapter = None if self.menu else CHAPTERS.get(m.group(1), "Campaign")
        elif MENU.search(line):
            self.loading, self.menu, self.chapter = False, True, None
        elif m := DIFFICULTY.search(line):
            self.difficulty = DIFFICULTIES.get(m.group(1).lower(), m.group(1).capitalize())

    def activity(self, started):
        state = None
        if self.menu:
            details = "Main menu"
        elif self.chapter:
            details = self.chapter
            if self.loading:
                state = "Loading"
            else:
                state = f"Campaign · {self.difficulty}" if self.difficulty else "Campaign"
        elif self.loading:
            details = "Loading"
        else:
            details = "Starting the game"
        activity = {"name": NAME, "details": details, "timestamps": {"start": int(started * 1000)}}
        if state:
            activity["state"] = state
        return activity


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def main():
    if len(sys.argv) != 3:
        print("usage: discord-presence.py <TF2VR/logs dir> <launcher pid>", file=sys.stderr)
        sys.exit(2)
    logs_dir, parent = sys.argv[1], int(sys.argv[2])
    started = time.time()
    game = Game(logs_dir, started)
    discord = Discord()
    sent = None
    announced = False
    next_try = 0.0
    while alive(parent):
        game.poll()
        if discord.sock is None and time.monotonic() >= next_try:
            if discord.connect():
                sent = None
                if not announced:
                    print(f'Discord: showing "Playing {NAME}"', flush=True)
                    announced = True
            else:
                next_try = time.monotonic() + 10
        if discord.sock is not None:
            try:
                activity = game.activity(started)
                if activity != sent:
                    discord.set_activity(activity)
                    sent = activity
                discord.pump(2)
                continue
            except IPC_ERRORS:
                discord.close()
                next_try = time.monotonic() + 10
        time.sleep(2)


if __name__ == "__main__":
    main()
