#!/usr/bin/env python3
# ============================================================================
# ROBLOX WATCHDOG v4.12 - interactive edition for Termux (rooted Android)
# + optional Hub control for FARMING <-> TRADING transitions
#
# Hub connection model:
#   PC:    hub.py listening on 0.0.0.0:8787 (or exposed via a tunnel)
#   PHONE: rw.py polls that address every few seconds
#
# No environment variables are required. Hub URL/token live in
# watchdog_config.json and can be edited from the menu.
#
# ----------------------------------------------------------------------------
# CHANGELOG (newest first) - check this against what you expect to confirm
# you actually pulled the latest version.
#
# v4.12
#   - ADD: the Sea 1/Sea 2 config switch no longer fails silently. If a clone has been up for 10 minutes and the Hub still reports no
#     sea for its account, watchdog.log says so (once per 30 min) with the likely reasons. `python3 rw.py hubcfg` now also prints each
#     clone's Hub account id and what the Hub said, so a mismatch between the watchdog's id and the in-game script's id is visible.
#
# v4.11
#   - REVERT: the Quantum config is no longer written before a TRADING launch (enter_trading is byte-for-byte the v4.2 sequence again:
#     force-stop, 1 s, launch). The trading server does not use the farm config, and writing it there only risked the trading join.
#     The config is still written before FARMING launches (restart, return to farming).
#
# v4.10
#   - ADD: automatic Sea 1 -> Sea 2 config switch. The Quantum config used to be written only when a clone was launched, so an account
#     that reached Sea 2 kept the Sea 1 farm settings until its next scheduled rejoin. Now, when the HUB reports a clone in a different
#     config group than the one last applied (Sea 1 vs Sea 2/3) for 2 minutes in a row, the watchdog restarts that clone once
#     (stop -> write the right config -> launch). Needs hub.py v2.9.5 (the sea is only trusted from the Hub, never from the Place ID).
#     Not during TRADING, not within 5 minutes of a launch, at most one such restart per clone per 30 minutes.
#     Switch off with hubcfg.restart_on_sea_change = false.
#
# v4.9
#   - ADD: `python3 rw.py stop` stops EVERYTHING: the supervisor first (so it cannot restart anything), then the watchdog (kill, and
#     kill -9 after 15 s if needed), as root, and prints what it did. `supervisor-stop` only ever stopped the supervisor - rw.py kept
#     running - and its message now says so. Menu 13 -> x does the full stop too.
#
# v4.8
#   - FIX: accounts on DIFFERENT phones were fused into one on the Hub. The Hub account id was a hash of "<package>:<Android uid>",
#     and two phones with the same clone package names installed in the same order have the same uid, so they got the same id.
#     New: a per-phone device name (watchdog_config.json -> "device_id", set with `python3 rw.py device-id <name>`) is mixed into the
#     hash and shown in front of the label on the dashboard. Without a device name nothing changes, so existing phones keep their
#     ids and history. Set it on the phone(s) that collide - ideally every phone except the oldest one.
#
# v4.7
#   - ADD: first launch of a NEW clone. The Quantum Onyx Hub folder and its file only exist after the script has run once, so the
#     template cannot be put there beforehand. The watchdog now remembers such a clone ("pending"); once the clone has been up
#     for 90 s it looks (quietly, once a minute) for the file, and as soon as it exists and differs from the template it restarts
#     that clone ONCE (stop -> write the config -> launch), instead of waiting for the next scheduled rejoin (up to 45 min).
#     Never during TRADING, and never more than one restart per clone per run for this reason.
#
# v4.6
#   - ADD: the hub config now comes from a link (hubcfg.url_sea2 = your repo's qntmcfgsea2.json), cached next to this script
#     (hubcfg_cache_sea2.json, refreshed every hubcfg.refresh_min minutes). If the download fails the cached copy is used, and
#     with no cache the local quantum_config_template.json.
#   - ADD: SEA-SPECIFIC CONFIG. A clone in Sea 1 gets the Sea 2 file with hubcfg.sea1_overrides applied (default: AutoFarm on, quest
#     farming, AutoSecondSea on, AutoChest off; Random_Auto and AutoStoreFruit stay on = it keeps rolling and storing fruits). Set
#     hubcfg.url_sea1 to use a separate file instead. The sea comes from the Hub (needs hub.py v2.9.5, which adds it to /poll), else
#     from the Place ID, else Sea 2 is assumed. Sea 3 uses the Sea 2 file.
#
# v4.5
#   - ADD: Quantum Onyx Hub config. Before every (re)launch - right after the clone is force-stopped, so the hub cannot overwrite it
#     while running - the watchdog overwrites each clone's `Arceus X/Workspace/Quantum Onyx Hub/*-BloxFruits-994732206.json` with
#     quantum_config_template.json (next to this script). The file name starts with the Roblox username, so it cannot be created
#     before the hub made it once: the first launch creates it, the next relaunch (rejoin) applies the template. Only files that
#     differ are rewritten. Menu 14 or `python3 rw.py hubcfg` applies it now. Settings: watchdog_config.json -> "hubcfg".
#
# v4.4
#   - FIX: the supervisor never stayed alive on this phone. The old launch (`setsid sh ... &` inside one `su -c`) was killed the
#     moment that `su` call returned (confirmed on-device: not even `sh -x` printed a line). The supervisor is now started by a
#     long-lived `su -c` child of this process (its own session, output in supervisor_launch.log), which is the only way
#     that was seen to work. It still lives inside Termux, so Termux must stay alive (oom protection + wake lock do that).
#   - ADD: `python3 rw.py install-boot` writes ~/.termux/boot/rw.sh (needs the Termux:Boot app, opened once). After a phone
#     restart it installs and starts the supervisor, which then starts the watchdog. Also menu 13 -> t.
#
# v4.3
#   - ADD: `python3 rw.py probe` collects LocalTrader_ItemProbe.txt (written by LocalTrader v2.6) from every clone and saves it as
#     item_probe_all.txt. It shows how skinned fruits (Divine Portal, Glacier Eagle, ...) appear in the game's trade inventory.
#
# v4.2
#   - Proof recorder understands the trade RESULT. LocalTrader now calls
#     RWProof.start() when the worker accepts / the countdown begins and
#     RWProof.done(rid, "completed" | "aborted" | "unverified") when the trade
#     ends. Aborted trades (customer left, timeout, stopped) are discarded
#     (keep_aborted = false); the others are saved as <id>_<clone>_<time>_<result>.mp4.
#   - screenrecord now starts BEFORE the clone is raised, so no frames of the
#     decisive moment are lost to the ~1 s the raise takes.
#   - max recording length 60 -> 90 s (only affects configs that never saved a
#     'proof' section; otherwise change max_sec in watchdog_config.json).
#
# v4.1
#   - Everything is in this one file: the proof recorder (no proof.py), the
#     auto-restart supervisor (menu 13 or `python3 rw.py install-supervisor`,
#     nothing to download) and the Lua helper (`python3 rw.py lua` writes
#     rwproof.lua next to this script).
#
# v4.0
#   - ADD: trade proof recorder. LocalTrader signals "confirm stage"
#     and "trade done" (see rwproof.lua); the watchdog raises that clone to the
#     front, records the screen, and saves <request_id>_<clone>_<time>.mp4 in
#     /storage/emulated/0/RWProof. Runs in its own threads. Menu option 12.
#   - FIX (crashes): the main loop is now wrapped, so one exception can no longer
#     end the watchdog; its traceback goes to watchdog.log. Terminal output errors
#     (closed session) switch to headless mode instead of crashing. SIGHUP is
#     ignored, SIGTERM is logged. sys.excepthook + faulthandler write to the log.
#   - FIX (load): the screen redraw used to run `su pidof` for every clone EVERY
#     SECOND (hundreds of su spawns per minute + log spam). It now shows the PID
#     found by tick().
#   - ADD: post-mortem. watchdog.alive is refreshed every 10 s and removed on a
#     clean exit; if it is still there at start-up the previous run was killed,
#     and the kill/lmkd lines from logcat are written to flight_recorder.log.
#   - ADD: `python3 rw.py watch` shows the live screen of a headless/root
#     instance (watchdog_screen.txt). Works with rw_supervisor.sh.
#   - ADD: deviceidle whitelist + kernel wake lock for Termux (root).
#
# v3.9
#   - ADD: LocalTrader autoexec. For every clone the watchdog now writes a small file into the clone's Autoexec
#     folder (found case-insensitively next to the Workspace; created if it does not exist) that runs
#         loadstring(game:HttpGet("<script_url>"))()
#     so LocalTrader starts by itself every time the game loads - no manual execution. It is checked at start-up,
#     before every (re)launch and from menu option 11, rewritten only when its content differs, and any OTHER
#     autoexec file that also mentions LocalTrader is reported (it would run twice). The file guards against
#     running twice in one server. Settings live in watchdog_config.json under "autoexec"
#     (enabled, script_url, file_name, dir_name, base_dir).
#
# v3.8
#   - FIX: "everything crashes after a trade". When the Hub flipped every
#     account TRADING -> FARMING, poll_hub() force-stopped and cold-started ALL
#     clones back to back (the launch stagger only existed in tick()). The
#     memory spike made Android's low-memory killer take the background clones
#     and Termux. Hub-triggered transitions are now QUEUED and run one clone
#     at a time, TRANSITION_GAP_SEC apart.
#   - ADD: Termux protection. At startup and every PROTECT_EVERY_SEC the
#     watchdog sets oom_score_adj -900 on com.termux and itself (root), and
#     calls termux-wake-lock once, so the low-memory killer prefers anything
#     else.
#   - NOTE: focus handoff (menu option 9) was tested on the real phone: moving focus away
#     from the clones hides ALL of them. It stays OFF; it is kept only as a test switch.
#   - ADD (OFF by default): "soft return" (menu option 10). On RETURN TO
#     FARMING, if the clone is already running it is NOT force-stopped; the
#     farming deep link is sent into the running clone instead, avoiding the
#     cold-start spike. Only enable if joining the link from inside a running
#     Roblox works on your clones.
#
# v3.7
#   - FIX: "zombie" clones. The clones are App Cloner clones, and App Cloner's
#     PersistentAppService restarts a clone's PROCESS (service only, no Activity)
#     right after the real process dies - the flight recorder caught this twice
#     (03:57 and 12:34, clone cliend). pidof then finds a PID, so the watchdog
#     reported "running", the Hub showed ONLINE, and nothing relaunched it until
#     its next scheduled rejoin (up to a full interval later), while no game was
#     open. tick() now also checks that the process owns an Activity (one
#     `dumpsys activity activities` per ~8 s, shared by all clones). A running
#     process with no Activity for 3 checks in a row is treated as dead and
#     relaunched; the Hub status shows "not running (no activity)" meanwhile.
#     Fail-safe: nothing is done if the dump is unusable, or if no configured
#     clone shows an Activity at all (nothing to validate the dump against).
#
# v3.6  (diagnostic build - for the "everything hides after a trade" problem)
#   - ADD: flight recorder -> flight_recorder.log (2 MB cap, rotates to .1).
#     At every transition that force-stops a clone (ENTER TRADING, RETURN TO
#     FARMING, any restart) it writes a snapshot BEFORE the stop and again
#     ~5 s, ~20 s and ~60 s later: which activity is on top / has focus, the PID
#     and uptime (ETIME) of system_server, com.og.launcher, Termux and every
#     Roblox clone, free memory, and (late snapshots) recent kill/death/start
#     events from logcat. Snapshots are scheduled, not slept on, so the watchdog
#     loop keeps running. First line records the Android version.
#   - ADD (experimental, OFF by default): "focus handoff". When ON, Termux is
#     brought to the front just before a clone is force-stopped, so the clone
#     being killed is not the focused window. Toggle with menu option 9.
#
# v3.5
#   - FIX: starting the watchdog no longer restarts clones that are already
#     running. A clone this process had never launched had last_rejoin == 0,
#     which counted as "due", so EVERY running clone was force-stopped within
#     seconds of startup (logged as "scheduled rejoin"). Running clones are now
#     "adopted": their rejoin timer starts from the moment the watchdog starts.
#   - ADD: staggered rejoin deadlines. Clones used to share the same start time
#     and so all came due together every interval, force-stopping the whole
#     fleet back to back. Each clone's deadline is now offset by its position
#     (clone k of N is due k/N of an interval earlier), spreading rejoins out.
#   - ADD: single-instance lock (watchdog.lock, flock). A second `rw.py start`
#     refuses to run and prints the PID of the one that holds the lock. The
#     lock is released automatically if the process dies. NOTE: older versions
#     (v3.4 and earlier) do not take the lock, so stop any old copies once.
#
# v3.4
#   - ADD: log rotation. watchdog.log is rotated to watchdog.log.1 at 5 MB
#     (one old copy kept), so it can never grow to hundreds of MB again.
#   - FIX: the Hub token no longer ends up in watchdog.log. The Workspace
#     config sync command contains the token (base64) and used to be logged
#     verbatim; it is now logged as "<redacted>".
#   - ADD: `id -u` result is cached (it never changes), removing about a third
#     of the log noise and a su-free subprocess call per command.
#   - FIX (crash-restart): error_dialog() used to grep ALL of `dumpsys window`
#     and return true if ANY window matched, so one match made EVERY clone
#     report "dialog" in the same tick and everything restarted together.
#     It is now per-package. health() also now has: a grace period after each
#     launch (no checks while the game is loading), a requirement that a clone
#     looks bad on 2 consecutive checks, a 5-minute minimum before "hung", and
#     a global minimum gap between crash restarts so clones restart one at a
#     time instead of all at once. dismiss_dialog() was removed: it sent
#     ENTER/BACK to whatever window was focused, possibly another clone.
#   - CHANGE: a not-running clone is now relaunched as soon as it has been
#     confirmed not running (3 polls), instead of waiting for its rejoin
#     timer (which could be up to 45 minutes). Launches are staggered by at
#     least LAUNCH_STAGGER_SEC so several cold starts never happen at once.
#   - ADD: "PROCESS STARTED / DIED" lines in the log, so
#     `grep PROCESS watchdog.log` shows exactly when each clone disappeared.
#   - FIX: Controller.pid() fallback matched package names by substring
#     (a running sibling clone could make a dead one look alive). It now
#     matches the exact process name.
#
# v3.3
#   - FIX: restart() called self.controller.wake()/self.controller.dismiss_dialog(),
#     but those methods live on Watchdog (self), not Controller - every restart
#     (i.e. every auto-rejoin) threw AttributeError before ever reaching
#     force_stop()/launch(), so nothing ever actually relaunched. Same class of
#     bug also existed in tick()'s self.controller.health(t) call and in
#     cpu_ticks()/error_dialog()/dismiss_dialog()/wake()/health() themselves,
#     which referenced self.s (Controller's shell handle) instead of self.shell
#     (Watchdog's). All corrected to call/reference the right object.
#   - ADD: restart() now rewrites LocalTrader_Hub.json (sync_localtrader_config)
#     immediately before every relaunch, not just Hub-triggered transitions, so
#     a game that relaunches on its own (e.g. a post-trade in-game teleport,
#     ahead of our own poll_hub() cycle) never reads a stale mode.
#   - FIX: sync_localtrader_config() could raise on bad Hub data (e.g. a
#     non-numeric quantity) and is now exception-safe end to end. This matters
#     beyond restart(): poll_hub() updates t.hub_state BEFORE calling this, so
#     an uncaught exception there used to permanently swallow a TRADING/FARMING
#     transition - the next poll wouldn't see a "change" either, since
#     t.hub_state already matched.
#   - ADD: launch()/launch_trading() now try a package-scoped `-p <package>`
#     variant of each intent first. Purely additive: if it doesn't confirm the
#     game joined, execution falls through to the exact same unqualified
#     attempts that already worked, unchanged. Fixes Android popping an
#     "Open with..." chooser when multiple Roblox clones all register the same
#     link and none is resolvable unambiguously.
#
# v3.2
#   - FIX: tick() could report "waiting for timer" forever and never
#     actually launch a not-running instance when crash_restart_enabled was
#     off (the default) - this was the "auto rejoin doesn't start Roblox"
#     bug. crash_restart_enabled now only gates aggressive restarts of a
#     running-but-unhealthy process; launching a genuinely not-running
#     instance (first launch, due schedule, or a dead TRADING session)
#     always works regardless of that toggle.
#   - FIX: launch()/launch_trading() declared success from `am start`'s own
#     return code alone; _wait() (which confirms the process actually
#     started) was defined but never called. Now every attempt is confirmed
#     before being declared successful, and full am start stdout/stderr is
#     logged so failures are diagnosable from watchdog.log.
#
# v3.1
#   - Restored has_root_access() (real `su` elevation test) after a rewrite
#     reverted it back to is_root() (checks if Termux itself is uid 0,
#     which is a different and mostly-always-false question).
#   - Restored crash_restart_enabled toggle (defaults OFF) after it was
#     dropped in a rewrite, leaving crash-based restarts always-on with no
#     way to disable them.
#   - Restored forced ICANON/ECHO/ISIG terminal setup at startup, and
#     restored TimeoutExpired/FileNotFoundError handling in Shell.run() -
#     both had been silently dropped in the same rewrite.
#   - Removed stdin=DEVNULL from su calls: this device's root prompt reads
#     its confirmation from stdin, so cutting stdin off made su fail
#     silently forever. Terminal is still force-resanitized after every
#     su call regardless of what that call did to it.
# ----------------------------------------------------------------------------

import base64
import dataclasses
import faulthandler
import fcntl
import hashlib
import json
import os
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import termios
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional, Tuple


VERSION = "4.12"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "watchdog_config.json")
LOG_PATH = os.path.join(BASE_DIR, "watchdog.log")
LOCK_PATH = os.path.join(BASE_DIR, "watchdog.lock")
RECORDER_PATH = os.path.join(BASE_DIR, "flight_recorder.log")
ALIVE_PATH = os.path.join(BASE_DIR, "watchdog.alive")
SCREEN_PATH = os.path.join(BASE_DIR, "watchdog_screen.txt")
FAULT_PATH = os.path.join(BASE_DIR, "watchdog_fault.log")
RECORDER_MAX_BYTES = 2_000_000
SNAPSHOT_DELAYS = (5, 20, 60)   # seconds after a transition

PACKAGE_MARKERS = ["roblox", "rbx"]
CLONER_BLOCKLIST = [
    "installer", "manager", "clone", "cloner", "parallel", "space", "island",
    "virtual", "multi", "dual", "2accounts", "multiple", "sandbox"
]

DEFAULT_TRADING_SHARE_LINK = (
    "https://www.roblox.com/share?code="
    "4e51df338208544d9be433e960693f11&type=Server"
)
DEFAULT_HUB_POLL_SEC = 3

# Workspace bridge used by the current LocalTrader. Each Roblox clone gets
# its own config inside its Workspace. This avoids relying on a
# shared LocalTrader_Order.json on the Termux side.
LOCALTRADER_CONFIG_NAME = "LocalTrader_Hub.json"

# v3.9: the autoexec file that starts LocalTrader inside the game.
LOCALTRADER_URL = "https://raw.githubusercontent.com/korent-cmd/decrypted_fluent/refs/heads/main/LocalTrader.lua"
DEFAULT_AUTOEXEC = {
    "enabled": True,
    "script_url": LOCALTRADER_URL,
    "file_name": "LocalTrader_autoexec.lua",
    "dir_name": "Arceus X/Autoexec",                  # "" = find the clone's autoexec folder by itself
    "base_dir": "/storage/emulated/0",    # where the RobloxCloneNNN folders live
}


# v4.5: the Quantum Onyx Hub settings file that every clone gets (see HubConfigInstaller).
DEFAULT_HUBCFG = {
    "enabled": True,
    "url_sea2": "https://raw.githubusercontent.com/korent-cmd/decrypted_fluent/refs/heads/main/qntmcfgsea2.json",
    "url_sea1": "",                                       # empty = Sea 2 file + sea1_overrides below
    "refresh_min": 10,                                    # how often the link is downloaded again
    "restart_on_sea_change": True,                        # restart a clone once when the Hub says it moved to another sea
    "sea1_overrides": {
        "AutoFarm": True,            # farm levels
        "FarmMode": "Quest",         # ...by quest
        "AcceptQuests": True,
        "AutoSecondSea": True,       # do the Second Sea quest at level 700
        "AutoChest": False,          # one mover at a time: level farming, not chest hunting
        "Random_Auto": True,         # keep rolling fruits
        "AutoStoreFruit": True,      # keep storing them
    },
    "template": "quantum_config_template.json",          # fallback when the link and the cache both fail
    "dir_name": "Arceus X/Workspace/Quantum Onyx Hub",     # inside each RobloxCloneNNN folder
    "file_glob": "*-BloxFruits-994732206.json",           # <roblox username>-BloxFruits-<game id>.json
    "base_dir": "/storage/emulated/0",
}


PLACE_SEA = {"2753915549": 1, "4442272183": 2, "7449423635": 3}   # Blox Fruits place ids


def resolve_sea(target: "Target", hub_sea: Optional[int] = None) -> Tuple[int, str]:
    """(sea, where it came from): the sea the Hub saw the account in, else the Place ID, else Sea 2."""
    try:
        hs = int(hub_sea or 0)
    except (TypeError, ValueError):
        hs = 0
    if hs in (1, 2, 3):
        return hs, "hub"
    ps = PLACE_SEA.get(str(getattr(target, "place_id", "") or "").strip())
    if ps:
        return ps, "place id"
    return 2, "default"


def now_str() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def clear_screen() -> None:
    try:
        if sys.stdout.isatty():
            os.system("clear")
    except Exception:
        pass


def acquire_instance_lock(path: str = LOCK_PATH):
    """Take an exclusive, non-blocking lock so only one watchdog runs at a time.

    Returns (file_handle, None) on success - keep the handle alive for as long
    as the watchdog runs. Returns (None, holder_pid_text) if another instance
    already holds the lock. The OS drops the lock automatically if the process
    exits or is killed, so a crash can never leave a stale lock behind.
    """
    fh = open(path, "a+")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        try:
            fh.seek(0)
            holder = fh.read().strip() or "unknown"
        except Exception:
            holder = "unknown"
        fh.close()
        return None, holder
    try:
        fh.seek(0)
        fh.truncate()
        fh.write(str(os.getpid()) + "\n")
        fh.flush()
    except Exception:
        pass
    return fh, None


def parse_private_link(value: str) -> str:
    """Extract a Roblox private-server code from share/legacy URLs or a bare code."""
    if not value:
        return ""
    value = value.strip()
    m = re.search(r"[?&](?:code|privateServerLinkCode|linkCode)=([^&]+)", value, re.I)
    if m:
        return urllib.parse.unquote(m.group(1))
    m = re.search(r"/share\?[^#]*?code=([^&]+)", value, re.I)
    if m:
        return urllib.parse.unquote(m.group(1))
    if re.fullmatch(r"[A-Za-z0-9_-]{8,}", value):
        return value
    return ""


DEVICE_ID = ""        # v4.8: this phone's name, set from watchdog_config.json before any Target is built


def clean_device_id(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", str(text or ""))[:20]


def account_id_for_target(t: "Target") -> str:
    if t.hub_id:
        return t.hub_id
    raw = (f"{DEVICE_ID}:{t.package}:{t.user_id}" if DEVICE_ID else f"{t.package}:{t.user_id}").encode("utf-8")
    return "rbx-" + hashlib.sha1(raw).hexdigest()[:12]


class Terminal:
    def __init__(self) -> None:
        self._fd = None
        self._old = None
        self._sane = None
        try:
            self._fd = sys.stdin.fileno()
            self._old = termios.tcgetattr(self._fd)
            # Force sane mode proactively (ICANON/ECHO/ISIG), rather than just
            # preserving whatever the incoming terminal state was. Some
            # remote/cloud-phone pty bridges start in a broken state (no line
            # buffering, no echo, Ctrl+C not delivered) - preserving that is
            # preserving the bug. This was lost in a prior rewrite; restoring it.
            sane = termios.tcgetattr(self._fd)
            sane[3] |= (termios.ICANON | termios.ECHO | termios.ISIG)
            termios.tcsetattr(self._fd, termios.TCSANOW, sane)
            self._sane = sane
        except Exception:
            self._fd = None
            self._old = None

    def sane(self) -> None:
        """Re-apply the forced-sane settings. Call after any subprocess call
        (especially `su`) that might have changed terminal mode."""
        if self._fd is None or self._sane is None:
            _resane_tty()
            return
        try:
            termios.tcsetattr(self._fd, termios.TCSANOW, self._sane)
        except Exception:
            pass

    def restore_original(self) -> None:
        if self._fd is None:
            return
        try:
            state = self._old if self._old is not None else _TTY_ORIGINAL_STATE
            if state is not None:
                termios.tcsetattr(self._fd, termios.TCSADRAIN, state)
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.restore_original()


# Capture the terminal state as early as possible, and force it sane
# (ICANON/ECHO/ISIG) immediately.  This is important for
# `python3 rw.py start`, which does not go through the interactive menu
# first, and it's also what _resane_tty() below restores to after every `su`
# call - if this were left unforced, _resane_tty() would keep restoring a
# broken state instead of fixing it.
try:
    _TTY_FD = sys.stdin.fileno()
    _TTY_ORIGINAL_STATE = termios.tcgetattr(_TTY_FD)
    _TTY_SANE_STATE = termios.tcgetattr(_TTY_FD)
    _TTY_SANE_STATE[3] |= (termios.ICANON | termios.ECHO | termios.ISIG)
    termios.tcsetattr(_TTY_FD, termios.TCSANOW, _TTY_SANE_STATE)
except Exception:
    _TTY_FD = None
    _TTY_ORIGINAL_STATE = None
    _TTY_SANE_STATE = None


def _resane_tty() -> None:
    """Restore the terminal mode after commands such as `su` return/timeout."""
    if _TTY_FD is None or _TTY_SANE_STATE is None:
        return
    try:
        termios.tcsetattr(_TTY_FD, termios.TCSANOW, _TTY_SANE_STATE)
    except Exception:
        pass


class Logger:
    MAX_BYTES = 5_000_000   # rotate at 5 MB, keeping one old copy (.1)

    def __init__(self, path: str) -> None:
        self.path = path
        self.lines: List[str] = []

    def log(self, msg: str) -> None:
        line = f"[{now_str()}] {msg}"
        self.lines.append(line)
        self.lines = self.lines[-80:]
        try:
            if os.path.getsize(self.path) > self.MAX_BYTES:
                os.replace(self.path, self.path + ".1")
        except OSError:
            pass  # file doesn't exist yet, or rotation failed; just keep logging
        try:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass


class Shell:
    def __init__(self, logger: Logger):
        self.logger = logger
        self._cache: Dict[str, str] = {}
        self._is_root: Optional[bool] = None

    def run(self, cmd: str, timeout: int = 10, check: bool = False,
            redact: bool = False) -> subprocess.CompletedProcess:
        # redact=True keeps the command text out of the log (used for the
        # Workspace config sync, whose command line contains the Hub token).
        shown = "<redacted>" if redact else cmd
        self.logger.log("$ " + shown)
        try:
            # NOTE: stdin is intentionally left connected (inherited), not
            # redirected to DEVNULL. Some root-manager prompts on this class
            # of device are text-based and read the yes/no answer from
            # stdin rather than showing a graphical system dialog - cutting
            # stdin off makes su fail silently forever, since the prompt can
            # never be answered. We rely on _resane_tty() below to clean up
            # any terminal-mode side effects instead of blocking input.
            p = subprocess.run(cmd, shell=True, text=True, capture_output=True,
                              timeout=timeout)
        except subprocess.TimeoutExpired:
            # Caught HERE, not just at individual call sites - force_stop(),
            # launch(), and launch_trading() call .root()/.run() directly
            # without their own try/except, so an uncaught timeout here
            # (e.g. su hanging on an unanswered root prompt) crashes the
            # whole script instead of just failing this one call. Confirmed
            # by direct test: a hung su reproduces exactly this traceback
            # without this handling.
            self.logger.log(f"TIMEOUT after {timeout}s: {shown}")
            _resane_tty()
            return subprocess.CompletedProcess(args=cmd, returncode=124, stdout="",
                                               stderr=f"timeout after {timeout}s")
        except FileNotFoundError as e:
            self.logger.log(f"NOT FOUND: {shown}: {e}")
            return subprocess.CompletedProcess(args=cmd, returncode=127, stdout="",
                                               stderr=str(e))
        finally:
            # `su` can leave the tty in raw/no-echo mode even after timeout or
            # process termination.  Restore it after every subprocess call.
            _resane_tty()

        if p.stdout.strip():
            self.logger.log(p.stdout.strip()[-1000:])
        if p.stderr.strip():
            self.logger.log("ERR " + p.stderr.strip()[-1000:])
        if check and p.returncode != 0:
            raise RuntimeError(f"command failed ({p.returncode}): {shown}")
        return p

    def out(self, cmd: str, timeout: int = 10) -> str:
        try:
            return self.run(cmd, timeout=timeout).stdout.strip()
        except Exception as e:
            self.logger.log(f"shell exception: {e}")
            return ""

    def cached(self, key: str, cmd: str, ttl: float = 5.0) -> str:
        stamp = f"__time__:{key}"
        last = getattr(self, stamp, 0.0)
        if time.monotonic() - last < ttl and key in self._cache:
            return self._cache[key]
        value = self.out(cmd)
        self._cache[key] = value
        setattr(self, stamp, time.monotonic())
        return value

    def is_root(self) -> bool:
        # The uid of this process never changes, so ask once and remember.
        if self._is_root is None:
            self._is_root = self.out("id -u") == "0"
        return self._is_root

    def has_root_access(self) -> bool:
        # is_root() only tells us whether Termux itself is already UID 0.
        # On a normal rooted phone Termux is not UID 0, but `su -c id` can
        # still elevate successfully. This is the original working check.
        if self.is_root():
            return True
        out = self.out("su -c id", timeout=15)
        return "uid=0" in out

    def root(self, cmd: str, timeout: int = 10, redact: bool = False) -> subprocess.CompletedProcess:
        if self.is_root():
            return self.run(cmd, timeout=timeout, redact=redact)
        return self.run("su -c " + shlex.quote(cmd), timeout=timeout, redact=redact)

    def root_out(self, cmd: str, timeout: int = 10) -> str:
        try:
            return self.root(cmd, timeout=timeout).stdout.strip()
        except Exception as e:
            self.logger.log(f"root exception: {e}")
            return ""


class Detector:
    def __init__(self, shell: Shell):
        self.s = shell

    def scan(self) -> List[Dict[str, Any]]:
        packages: Dict[str, Dict[str, Any]] = {}
        raw = self.s.root_out("pm list packages -U 2>/dev/null")
        for line in raw.splitlines():
            line = line.strip()
            if not line.startswith("package:"):
                continue
            body = line[8:]
            parts = body.split()
            package = parts[0]
            uid = 0
            for p in parts[1:]:
                if p.startswith("uid:"):
                    try:
                        uid = int(p[4:])
                    except ValueError:
                        pass
            low = package.lower()
            if not any(x in low for x in PACKAGE_MARKERS):
                continue
            if any(x in low for x in CLONER_BLOCKLIST):
                continue
            packages[package] = {"package": package, "uid": uid}

        # Fallback to pm list packages when -U is unavailable.
        if not packages:
            raw = self.s.root_out("pm list packages 2>/dev/null")
            for line in raw.splitlines():
                if line.startswith("package:"):
                    package = line[8:].strip()
                    low = package.lower()
                    if any(x in low for x in PACKAGE_MARKERS) and not any(x in low for x in CLONER_BLOCKLIST):
                        packages[package] = {"package": package, "uid": 0}

        return list(packages.values())

    def processes(self) -> str:
        return self.s.root_out("ps -A 2>/dev/null")

    def package_path(self, package: str) -> str:
        return self.s.root_out(f"pm path {shlex.quote(package)} 2>/dev/null")


@dataclass
class Target:
    package: str
    user_id: int = 0
    place_id: str = ""
    private_link: str = ""
    rejoin_interval_min: int = 45
    label: str = ""
    enabled: bool = True
    hub_id: str = ""

    last_rejoin: float = 0.0
    last_launch: float = 0.0
    last_heartbeat: float = 0.0
    cpu: str = "-"
    stale: bool = False
    last_cpu: Optional[int] = None
    stale_ticks: int = 0
    not_running_ticks: int = 0
    fail_streak: int = 0
    cooldown_until: float = 0.0
    restarts: int = 0
    status: str = "stopped"
    hub_state: str = "FARMING"
    hub_request_id: str = ""
    hub_version: int = 0
    hub_error: str = ""
    trading_join_attempted: bool = False
    clone_folder: str = ""

    def __post_init__(self) -> None:
        if not self.label:
            self.label = self.package
        if not self.hub_id:
            self.hub_id = account_id_for_target(self)


class HubClient:
    """Tiny stdlib-only client for hub.py."""

    def __init__(self, base_url: str, token: str, logger: Logger, timeout: int = 5):
        self.base_url = base_url.rstrip("/")
        self.token = token.strip()
        self.logger = logger
        self.timeout = timeout

    @property
    def enabled(self) -> bool:
        return bool(self.base_url and self.token)

    def _request(self, method: str, path: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        url = self.base_url + path
        data = None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                raw = r.read().decode("utf-8", errors="replace")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Hub HTTP {e.code}: {body[:300]}")
        except Exception as e:
            raise RuntimeError(str(e))

    def heartbeat(self, t: Target, status: str, mode: str) -> Dict[str, Any]:
        return self._request("POST", "/api/v1/heartbeat", {
            "account_id": t.hub_id,
            "package": t.package,
            "user_id": t.user_id,
            "label": (f"{DEVICE_ID}:{t.label}" if DEVICE_ID else t.label),
            "status": status,
            "mode": mode,
        })

    def poll(self, t: Target) -> Dict[str, Any]:
        return self._request("GET", "/api/v1/poll/" + urllib.parse.quote(t.hub_id, safe=""))

    def event(self, t: Target, status: str, event: str, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        body = {
            "account_id": t.hub_id,
            "status": status,
            "event": event,
            "extra": extra or {},
        }
        return self._request("POST", "/api/v1/event", body)


class Controller:
    def __init__(self, shell: Shell, logger: Logger):
        self.s = shell
        self.log = logger

    def pid(self, package: str) -> str:
        out = self.s.root_out(f"pidof {shlex.quote(package)} 2>/dev/null")
        if out:
            return out.split()[0]
        # v3.4: exact process-name match. The old `grep -F <package>` was a
        # substring match, so a running sibling clone whose name merely
        # contained this package name could make a dead one look alive.
        out = self.s.root_out(
            f"ps -A 2>/dev/null | awk -v p={shlex.quote(package)} '$NF==p{{print $2; exit}}'"
        )
        if out.strip():
            return out.strip().split()[0]
        # Fallback for installs whose actual running process name doesn't
        # match their package name at all - common with APK-cloned or
        # repackaged Roblox instances, which can leave pidof and the
        # name match above unable to ever find the process even while it's
        # genuinely running. Every installed package still gets its own
        # unique Android UID from the package manager, so resolve that and
        # match a running process by UID instead. Purely additive: only
        # tried if both checks above found nothing, so it can't change
        # behavior for anything that already worked. EXPERIMENTAL: the
        # exact `ps -o` column syntax varies by device/toolchain (toybox
        # vs busybox) and hasn't been verified on-device - if this doesn't
        # work, App.diagnostics() (menu option 6) now prints the raw output
        # of every step here per target, so we can see exactly what came
        # back instead of guessing again.
        uid = self.resolve_uid(package)
        if uid is not None:
            out = self.s.root_out(
                f"ps -Ao PID,UID,NAME 2>/dev/null | awk -v u={uid} '$2==u{{print $1; exit}}'"
            )
            if out.strip():
                return out.strip().split()[0]
        return ""

    def resolve_uid(self, package: str) -> Optional[int]:
        out = self.s.root_out(f"pm list packages -U 2>/dev/null | grep -F {shlex.quote('package:' + package + ' ')}")
        for token in out.split():
            if token.startswith("uid:"):
                try:
                    return int(token[4:])
                except ValueError:
                    return None
        return None

    def is_running(self, package: str) -> bool:
        return bool(self.pid(package))

    def force_stop(self, t: Target) -> None:
        self.s.root(f"am force-stop {shlex.quote(t.package)} 2>/dev/null", timeout=10)
        time.sleep(1)

    def launch(self, t: Target) -> bool:
        """Launch farming using the older, known-good intent order.

        IMPORTANT: do not package-qualify the VIEW deep link. The newer
        versions changed this and that broke game joining on the cloned
        Roblox installs. We keep the proven resolver path, then use an
        exact-package launcher only as the final fallback.

        Every attempt is now confirmed by actually waiting for the process
        to appear (self._wait), not just trusting `am start`'s own return
        code. `am start` can return 0 even when the intent resolved to the
        wrong screen (e.g. Roblox's home screen instead of the specific
        game) or didn't fully complete - a 0 return code alone was making
        the watchdog falsely believe a launch had succeeded.
        """
        if not t.place_id:
            self.log.log(f"{t.label}: no place_id configured")
            return False

        code = parse_private_link(t.private_link)
        intents: List[str] = []
        if code:
            intents.append(
                f"https://www.roblox.com/games/start?placeId={urllib.parse.quote(t.place_id)}&linkCode={urllib.parse.quote(code)}"
            )
            intents.append(
                f"roblox://placeId={urllib.parse.quote(t.place_id)}&linkCode={urllib.parse.quote(code)}"
            )
        intents.append(f"roblox://placeId={urllib.parse.quote(t.place_id)}")
        intents.append(f"https://www.roblox.com/games/start?placeId={urllib.parse.quote(t.place_id)}")

        # This is intentionally the v3.1/proven path: implicit VIEW intent
        # first. Android resolves the deep link through the Roblox clone's
        # registered intent filter. Package qualification is NOT used here.
        for url in intents:
            # NEW in v3.3, purely additive: try this same link scoped to just
            # this package first. -p only narrows which package's intent
            # filters may resolve the VIEW action - the app still handles the
            # link exactly as it would implicitly, it just stops Android from
            # offering a same-domain "Open with..." chooser when several
            # Roblox clones are installed side by side and all declare the
            # same intent filter. This is NOT the same as an explicit
            # component (-n package/Activity), which is what broke game
            # joining previously (see v3.1 note below) by bypassing intent
            # filter matching entirely. If this doesn't confirm running, we
            # fall straight through to the exact unqualified attempt that
            # already worked, unchanged.
            self.log.log(f"{t.label}: launching farming URL {url} (package-scoped)")
            p_scoped = self.s.root(
                "am start -W -a android.intent.action.VIEW -d "
                + shlex.quote(url) + " -p " + shlex.quote(t.package),
                timeout=20,
            )
            out_scoped = (p_scoped.stdout or "").strip()
            err_scoped = (p_scoped.stderr or "").strip()
            if out_scoped:
                self.log.log(f"{t.label}: am start (package-scoped) stdout: {out_scoped[:400]}")
            if err_scoped:
                self.log.log(f"{t.label}: am start (package-scoped) stderr: {err_scoped[:400]}")
            if p_scoped.returncode == 0 and self._wait(t, seconds=12):
                t.last_launch = time.time()
                t.status = "launching"
                self.log.log(f"{t.label}: confirmed running after package-scoped intent")
                return True

            self.log.log(f"{t.label}: launching farming URL {url}")
            p = self.s.root(
                "am start -W -a android.intent.action.VIEW -d "
                + shlex.quote(url),
                timeout=20,
            )
            out = (p.stdout or "").strip()
            err = (p.stderr or "").strip()
            if out:
                self.log.log(f"{t.label}: am start stdout: {out[:400]}")
            if err:
                self.log.log(f"{t.label}: am start stderr: {err[:400]}")

            if p.returncode != 0:
                self.log.log(f"{t.label}: am start rc={p.returncode}, trying next format")
                continue

            if self._wait(t, seconds=12):
                t.last_launch = time.time()
                t.status = "launching"
                self.log.log(f"{t.label}: confirmed running after this intent")
                return True
            self.log.log(f"{t.label}: am start rc=0 but process never appeared, trying next format")

        # Last resort: explicitly open this exact clone.
        p = self.s.root(
            "monkey -p " + shlex.quote(t.package) +
            " -c android.intent.category.LAUNCHER 1",
            timeout=20,
        )
        if p.returncode == 0 and self._wait(t, seconds=15):
            t.last_launch = time.time()
            t.status = "launching"
            self.log.log(f"{t.label}: launcher fallback confirmed running "
                        f"(NOTE: this only opens the app, it does not join "
                        f"the game - every deep-link format failed)")
            return True
        self.log.log(f"{t.label}: every launch attempt failed, including launcher fallback")
        return False

    def launch_trading(self, t: Target, share_link: str) -> bool:
        """Join the proven trading PS share-link.

        v3.3: tries a package-scoped (-p) attempt first (see the matching
        comment in launch() for why that differs from the -n component
        targeting that caused the original regression), then falls straight
        through, unchanged, to the plain implicit share-link intent below -
        that fallback is still the tested working baseline and is left as-is.
        """
        code = parse_private_link(share_link)
        if not code:
            self.log.log(f"{t.label}: invalid trading share link")
            return False

        uri = (
            "roblox://navigation/share_links?code="
            + urllib.parse.quote(code)
            + "&type=Server"
        )

        self.log.log(f"{t.label}: trading deep-link attempt (package-scoped)")
        p_scoped = self.s.root(
            "am start -W -a android.intent.action.VIEW -d " + shlex.quote(uri)
            + " -p " + shlex.quote(t.package),
            timeout=25,
        )
        out_scoped = (p_scoped.stdout or "").strip()
        err_scoped = (p_scoped.stderr or "").strip()
        if out_scoped:
            self.log.log(f"{t.label}: am start (package-scoped) stdout: {out_scoped[:400]}")
        if err_scoped:
            self.log.log(f"{t.label}: am start (package-scoped) stderr: {err_scoped[:400]}")
        if p_scoped.returncode == 0 and self._wait(t, seconds=15):
            t.last_launch = time.time()
            t.status = "trading_joining"
            self.log.log(f"{t.label}: confirmed running after package-scoped trading intent")
            return True

        self.log.log(f"{t.label}: trading deep-link attempt (implicit resolver)")
        p = self.s.root(
            "am start -W -a android.intent.action.VIEW -d " + shlex.quote(uri),
            timeout=25,
        )
        out = (p.stdout or "").strip()
        err = (p.stderr or "").strip()
        if out:
            self.log.log(f"{t.label}: am start stdout: {out[:400]}")
        if err:
            self.log.log(f"{t.label}: am start stderr: {err[:400]}")

        if p.returncode == 0 and self._wait(t, seconds=15):
            t.last_launch = time.time()
            t.status = "trading_joining"
            self.log.log(f"{t.label}: confirmed running after trading intent")
            return True
        self.log.log(f"{t.label}: trading launch failed "
                    f"(rc={p.returncode}, confirmed_running={self.is_running(t.package)})")
        return False

    def _wait(self, t: Target, seconds: int = 15) -> bool:
        deadline = time.time() + seconds
        while time.time() < deadline:
            if self.is_running(t.package):
                return True
            time.sleep(0.5)
        return False


class AutoexecInstaller:
    """Puts a file into each clone's autoexec folder that runs LocalTrader. Uses root shell commands only."""
    RECHECK_SEC = 300

    FIND_DIR = r'''
c=@@BASE@@; f=@@FILE@@; hint=@@HINT@@
[ -d "$c" ] || { echo "AUTOEXEC_ERR clone folder missing: $c" >&2; exit 2; }
d=""
if [ -n "$hint" ] && [ -d "$c/$hint" ]; then d="$c/$hint"; fi
if [ -z "$d" ]; then
  for x in "$c"/* "$c/Arceus X"/*; do
    [ -d "$x" ] || continue
    n=$(echo "${x##*/}" | tr 'A-Z' 'a-z')
    case "$n" in autoexec*) d="$x"; break;; esac
  done
fi
'''
    INSTALL = FIND_DIR + r'''
created=""
if [ -z "$d" ]; then
  d="$c/${hint:-Autoexec}"; created=" created"
  mkdir -p "$d" || { echo "AUTOEXEC_ERR cannot create $d" >&2; exit 3; }
fi
want=$(echo @@B64@@ | base64 -d)
if [ -f "$d/$f" ] && [ "$(cat "$d/$f")" = "$want" ]; then
  st=same
else
  tmp="$d/.$f.tmp"
  { echo @@B64@@ | base64 -d > "$tmp" && mv -f "$tmp" "$d/$f"; } || { echo "AUTOEXEC_ERR write failed in $d" >&2; exit 4; }
  chmod 666 "$d/$f" 2>/dev/null
  st=written
fi
echo "AUTOEXEC_OK $st $d$created"
dups=$(grep -l -i 'localtrader' "$d"/* 2>/dev/null | grep -v -F "$d/$f" | tr '\n' ' ')
[ -n "$dups" ] && echo "AUTOEXEC_DUP $dups"
exit 0
'''
    REMOVE = FIND_DIR + r'''
if [ -z "$d" ]; then echo "AUTOEXEC_OK none"; exit 0; fi
if [ -f "$d/$f" ]; then rm -f "$d/$f" && echo "AUTOEXEC_OK removed $d"; else echo "AUTOEXEC_OK none $d"; fi
exit 0
'''

    def __init__(self, shell: Shell, logger: Logger, cfg: Optional[dict] = None):
        self.shell = shell
        self.log = logger
        self.cfg = {**DEFAULT_AUTOEXEC, **(cfg or {})}

    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled", True))

    def lua(self) -> str:
        url = (self.cfg.get("script_url") or LOCALTRADER_URL).strip().replace("\\", "\\\\").replace('"', '\\"')
        return (
            "-- Written by the Roblox watchdog: starts LocalTrader every time the game loads.\n"
            "-- Do not edit here; the address comes from watchdog_config.json -> autoexec.script_url\n"
            'local env = (type(getgenv) == "function" and getgenv()) or _G\n'
            "if env.__LocalTraderAutoexec == game.JobId then return end\n"
            "env.__LocalTraderAutoexec = game.JobId\n"
            f'loadstring(game:HttpGet("{url}"))()\n'
        )

    def file_name(self) -> str:
        return os.path.basename(str(self.cfg.get("file_name") or "")) or DEFAULT_AUTOEXEC["file_name"]

    def clone_name_for(self, target: "Target", targets: List["Target"]) -> str:
        name = target.clone_folder
        if not name:
            m = re.search(r"RobloxClone\d+", target.label or "")
            name = m.group(0) if m else ""
        if not name:
            try:
                ordinal = targets.index(target) + 1
            except ValueError:
                ordinal = 1
            name = f"RobloxClone{ordinal:03d}"
        target.clone_folder = name
        return name

    def _script(self, template: str, target: "Target", targets: List["Target"], b64: str = "") -> str:
        base = str(self.cfg.get("base_dir") or DEFAULT_AUTOEXEC["base_dir"]).rstrip("/")
        clone = self.clone_name_for(target, targets)
        return (template.replace("@@BASE@@", shlex.quote(f"{base}/{clone}"))
                        .replace("@@FILE@@", shlex.quote(self.file_name()))
                        .replace("@@HINT@@", shlex.quote(str(self.cfg.get("dir_name") or "")))
                        .replace("@@B64@@", shlex.quote(b64)))

    def ensure(self, target: "Target", targets: List["Target"], force: bool = False) -> Tuple[bool, str]:
        """Make sure the clone's autoexec folder holds the LocalTrader starter. Never raises."""
        if not self.enabled:
            return False, "autoexec is switched off"
        now = time.time()
        if not force and now - getattr(target, "_autoexec_at", 0.0) < self.RECHECK_SEC:
            return True, "checked recently"
        try:
            b64 = base64.b64encode(self.lua().encode("utf-8")).decode("ascii")
            res = self.shell.root(self._script(self.INSTALL, target, targets, b64), timeout=25, redact=True)
            out = (res.stdout or "") + "\n" + (res.stderr or "")
            m = re.search(r"AUTOEXEC_OK (written|same) (.+?)(?: (created))?$", out, re.M)
            if res.returncode != 0 or not m:
                err = re.search(r"AUTOEXEC_ERR (.+)", out)
                msg = err.group(1).strip() if err else (out.strip()[-200:] or f"exit code {res.returncode}")
                self.log.log(f"{target.label}: autoexec install FAILED: {msg}")
                return False, msg
            state, folder, created = m.group(1), m.group(2).strip(), bool(m.group(3))
            target._autoexec_at = now
            dup = re.search(r"AUTOEXEC_DUP (.+)", out)
            if dup and not getattr(target, "_autoexec_dup_logged", False):
                target._autoexec_dup_logged = True
                self.log.log(f"{target.label}: WARNING another autoexec file also mentions LocalTrader and would run it twice: {dup.group(1).strip()}")
            if state == "written" or not getattr(target, "_autoexec_logged", False):
                target._autoexec_logged = True
                extra = " (the folder did not exist, so I created it - if LocalTrader does not start, tell me the real autoexec folder name)" if created else ""
                self.log.log(f"{target.label}: autoexec {'written' if state == 'written' else 'already in place'}: {folder}/{self.file_name()}{extra}")
            return True, f"{state}: {folder}/{self.file_name()}" + (" [folder created]" if created else "") + (f" [WARNING also: {dup.group(1).strip()}]" if dup else "")
        except Exception as e:
            self.log.log(f"{target.label}: autoexec install error: {type(e).__name__}: {e}")
            return False, f"{type(e).__name__}: {e}"

    def remove(self, target: "Target", targets: List["Target"]) -> Tuple[bool, str]:
        try:
            res = self.shell.root(self._script(self.REMOVE, target, targets), timeout=25)
            out = (res.stdout or "") + (res.stderr or "")
            target._autoexec_at = 0.0
            if "AUTOEXEC_OK removed" in out:
                return True, "removed"
            if "AUTOEXEC_OK none" in out:
                return True, "nothing to remove"
            return False, out.strip()[-200:] or f"exit code {res.returncode}"
        except Exception as e:
            return False, f"{type(e).__name__}: {e}"


class HubConfigInstaller:
    """Overwrites the Quantum Onyx Hub settings file in each clone with the right config for its sea. Root shell commands only.

    The config is downloaded from a link (cached; falls back to the cache, then to a local template). A Sea 1 clone gets the
    Sea 2 file with sea1_overrides applied, unless url_sea1 is set. The hub names its file <roblox username>-BloxFruits-<game id>.json,
    so it can only be EDITED once the hub has created it (first launch); a clone without that file yet is picked up at its next relaunch.
    """
    SCRIPT = r'''
src=@@SRC@@; d=@@DIR@@; g=@@GLOB@@; dry=@@DRY@@
[ -r "$src" ] || { echo "HUBCFG_ERR template not readable: $src" >&2; exit 2; }
[ -d "$d" ] || { echo "HUBCFG_OK found=0 written=0 nodir"; exit 0; }
n=0; w=0
for f in "$d"/$g; do
  [ -f "$f" ] || continue
  n=$((n+1))
  if cmp -s "$src" "$f"; then continue; fi
  if [ "$dry" = 1 ]; then w=$((w+1)); continue; fi
  tmp="$f.rwtmp"
  { cp "$src" "$tmp" && mv -f "$tmp" "$f"; } || { rm -f "$tmp"; echo "HUBCFG_ERR write failed: $f" >&2; exit 4; }
  chmod 666 "$f" 2>/dev/null
  w=$((w+1))
done
echo "HUBCFG_OK found=$n written=$w"
exit 0
'''

    def __init__(self, shell: Shell, logger: Logger, cfg: Optional[dict], namer: Callable[..., str],
                 sea_fn: Optional[Callable[["Target"], Tuple[int, str]]] = None,
                 quiet_run: Optional[Callable[[str, int], str]] = None):
        self.shell = shell
        self.quiet_run = quiet_run     # runs a root script WITHOUT writing it to watchdog.log; returns stdout (+ "ERR ..." lines)
        self.log = logger
        self.cfg = {**DEFAULT_HUBCFG, **(cfg or {})}
        self.namer = namer
        self.sea_fn = sea_fn or (lambda t: resolve_sea(t, 0))
        self._warned: Dict[str, str] = {}

    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled", True))

    def _local(self, name: str) -> str:
        return name if os.path.isabs(name) else os.path.join(BASE_DIR, name)

    def template_path(self) -> str:
        return self._local(str(self.cfg.get("template") or DEFAULT_HUBCFG["template"]))

    @staticmethod
    def _valid(raw: bytes) -> Optional[dict]:
        try:
            if not raw or len(raw) > 2_000_000:
                return None
            data = json.loads(raw.decode("utf-8-sig"))
            return data if isinstance(data, dict) and data else None
        except Exception:
            return None

    def _note(self, key: str, msg: str) -> None:
        """Log a message only when it differs from the last one for this key (keeps watchdog.log quiet)."""
        if self._warned.get(key) != msg:
            self._warned[key] = msg
            self.log.log("hub config: " + msg)

    def fetch(self, url: str, cache_name: str) -> Tuple[Optional[str], str]:
        """(path of a usable local copy, where it came from). Downloads at most every refresh_min minutes."""
        cache = self._local(cache_name)
        refresh = max(1, int(self.cfg.get("refresh_min") or 10)) * 60
        try:
            if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < refresh and self._valid(open(cache, "rb").read()):
                return cache, "cache"
        except OSError:
            pass
        err = ""
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "rw-watchdog", "Cache-Control": "no-cache"})
            with urllib.request.urlopen(req, timeout=10) as r:
                raw = r.read(2_000_001)
            if self._valid(raw) is None:
                err = "the download is not a valid JSON object"
            else:
                tmp = cache + ".tmp"
                with open(tmp, "wb") as f:
                    f.write(raw)
                os.replace(tmp, cache)
                self._note("dl:" + cache_name, f"downloaded {url.rsplit('/', 1)[-1]} ({len(raw)} bytes)")
                return cache, "download"
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
        try:
            if self._valid(open(cache, "rb").read()):
                self._note("dl:" + cache_name, f"download failed ({err}); using the cached copy")
                return cache, "stale cache"
        except OSError:
            pass
        self._note("dl:" + cache_name, f"download failed ({err}) and there is no cached copy")
        return None, err

    def base_config(self, url: str, cache_name: str) -> Tuple[Optional[str], str]:
        """The Sea 2 style file: the link, else the cache, else the local template."""
        if url:
            path, how = self.fetch(url, cache_name)
            if path:
                return path, how
        t = self.template_path()
        try:
            if self._valid(open(t, "rb").read()):
                return t, "local template"
        except OSError:
            pass
        return None, f"no usable config (link failed, {t} missing or invalid)"

    @staticmethod
    def _set_where_present(obj: dict, overrides: dict) -> int:
        n = 0
        for k, v in overrides.items():
            if k in obj:
                obj[k] = v
                n += 1
        return n

    def source_for(self, sea: int) -> Tuple[Optional[str], str]:
        """Local file to copy into the clones for this sea, and a short description of where it came from."""
        url2 = str(self.cfg.get("url_sea2") or "").strip()
        url1 = str(self.cfg.get("url_sea1") or "").strip()
        if sea == 1 and url1:
            path, how = self.base_config(url1, "hubcfg_cache_sea1.json")
            return path, f"Sea 1 file, {how}"
        path, how = self.base_config(url2, "hubcfg_cache_sea2.json")
        if path is None or sea != 1:
            return path, f"Sea {2 if sea != 1 else 1} file, {how}"
        over = self.cfg.get("sea1_overrides") or {}
        if not over:
            return path, f"Sea 2 file (no Sea 1 overrides set), {how}"
        try:
            data = json.loads(open(path, "rb").read().decode("utf-8-sig"))
            hits = self._set_where_present(data, over)
            for slot in data.get("_saveSlots") or []:
                if isinstance(slot, dict) and isinstance(slot.get("data"), dict):
                    hits += self._set_where_present(slot["data"], over)
            out = self._local("hubcfg_sea1_generated.json")
            tmp = out + ".tmp"
            with open(tmp, "w", encoding="utf-8", newline="\n") as f:
                f.write(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n")
            os.replace(tmp, out)
            return out, f"Sea 2 file + Sea 1 overrides ({hits} values set), {how}"
        except Exception as e:
            return None, f"could not build the Sea 1 config: {type(e).__name__}: {e}"

    def template_problem(self) -> str:
        """Empty string if some usable config can be produced right now."""
        path, how = self.base_config(str(self.cfg.get("url_sea2") or "").strip(), "hubcfg_cache_sea2.json")
        return "" if path else how

    def _run(self, script: str, timeout: int) -> Tuple[int, str]:
        if self.quiet_run:
            out = self.quiet_run(script, timeout)
            return (0 if "HUBCFG_OK" in out else 1), out
        res = self.shell.root(script, timeout=timeout)
        return res.returncode, (res.stdout or "") + "\n" + (res.stderr or "")

    def pending_check(self, target: "Target", targets: List["Target"]) -> Tuple[int, int]:
        """Quiet, read-only: (config files found in the clone, how many of them differ from what apply() would write)."""
        sea, _src = self.sea_fn(target)
        src, _how = self.source_for(sea)
        if not src:
            return 0, 0
        ok, msg, found, written = self._apply_inner(target, targets, src, sea, "", dry=True)
        return found, written

    def apply(self, target: "Target", targets: List["Target"]) -> Tuple[bool, str]:
        """Never raises. Returns (ok, message)."""
        if not self.enabled:
            return False, "hub config is switched off"
        try:
            sea, sea_src = self.sea_fn(target)
            src, how = self.source_for(sea)
            if not src:
                if getattr(target, "_hubcfg_last", "") != how:
                    target._hubcfg_last = how
                    self.log.log(f"{target.label}: hub config NOT applied: {how}")
                return False, how
            tag = f"[sea {sea} from {sea_src}: {how}]"
            ok, msg, found, written = self._apply_inner(target, targets, src, sea, tag, dry=False)
            target._hubcfg_pending = bool(ok and found == 0)       # the hub has not made its file yet: watch for it
            if ok and found > 0:
                target._hubcfg_sea = sea                           # which config this clone is running now
                target._hubcfg_sea_src = sea_src
            if ok and (written or getattr(target, "_hubcfg_last", "") != msg):
                target._hubcfg_last = msg
                self.log.log(f"{target.label}: hub config: {msg}")
            return ok, msg
        except Exception as e:
            self.log.log(f"{target.label}: hub config error: {type(e).__name__}: {e}")
            return False, f"{type(e).__name__}: {e}"


    def _apply_inner(self, target, targets, src: str, sea: int, tag: str, dry: bool):
        """Run the copy script for one clone. Returns (ok, message, files found, files written / that would be written)."""
        base = str(self.cfg.get("base_dir") or DEFAULT_HUBCFG["base_dir"]).rstrip("/")
        clone = self.namer(target, targets)
        folder = f"{base}/{clone}/{str(self.cfg.get('dir_name') or DEFAULT_HUBCFG['dir_name']).strip('/')}"
        script = (self.SCRIPT.replace("@@SRC@@", shlex.quote(src))
                             .replace("@@DIR@@", shlex.quote(folder))
                             .replace("@@GLOB@@", shlex.quote(str(self.cfg.get("file_glob") or DEFAULT_HUBCFG["file_glob"])))
                             .replace("@@DRY@@", "1" if dry else "0"))
        rc, out = self._run(script, 25)
        m = re.search(r"HUBCFG_OK found=(\d+) written=(\d+)", out)
        if rc != 0 or not m:
            err = re.search(r"HUBCFG_ERR (.+)", out)
            msg = err.group(1).strip() if err else (out.strip()[-200:] or f"exit code {rc}")
            if not dry:
                self.log.log(f"{target.label}: hub config FAILED: {msg}")
            return False, msg, 0, 0
        found, written = int(m.group(1)), int(m.group(2))
        if found == 0:
            msg = (f"no config file yet in {folder} (matching {self.cfg.get('file_glob')}); the hub creates it after its first "
                   f"load, the clone will be restarted once when it shows up {tag}")
        elif written:
            msg = f"written into {written} of {found} file(s) in {folder} {tag}"
        else:
            msg = f"already identical ({found} file(s)) {tag}"
        return True, msg, found, written


# ============================================================================
# Trade proof recorder (v4.x, built in).
# LocalTrader signals "start" (confirm stage) and "done" (trade complete) over
#   http://127.0.0.1:<port>/proof/start|done?account=<id>&id=<request_id>
# or via <clone>/Arceus X/Workspace/LocalTrader_Signal.json. Between the two, the
# trading clone is raised to the front and the screen is recorded.
# Runs in its own threads, so a slow tick() never delays a recording.
# ============================================================================
SIGNAL_FILE = "LocalTrader_Signal.json"

DEFAULT_PROOF: Dict[str, Any] = {
    "enabled": True,
    "port": 8799,
    "dir": "/storage/emulated/0/RWProof",
    "bring_to_front": True,      # raise the trading clone before recording
    "tail_sec": 1.5,             # keep recording this long after "done"
    "max_sec": 90,               # hard cap per recording (screenrecord max is 180)
    "keep_aborted": False,       # discard recordings of trades that did not complete
    "bit_rate": 2000000,
    "keep_last_sec": 12,         # trim to the last N seconds if ffmpeg exists (0 = keep all)
    "keep_days": 14,             # delete proof videos older than this
    "file_poll": True,
    "file_poll_sec": 1.0,
    "ffmpeg": "/data/data/com.termux/files/usr/bin/ffmpeg",
}


def _safe(text: str, n: int = 40) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(text or ""))[:n] or "x"


class ProofRecorder:
    def __init__(self, shell, logger, get_targets: Callable[[], list],
                 cfg: Optional[dict] = None,
                 on_saved: Optional[Callable[[Any, str, str], None]] = None,
                 is_trading: Optional[Callable[[Any], bool]] = None,
                 resane: Optional[Callable[[], None]] = None):
        self.shell = shell
        self.log = logger
        self.get_targets = get_targets
        self.cfg = {**DEFAULT_PROOF, **(cfg or {})}
        self.on_saved = on_saved
        self.is_trading = is_trading or (lambda t: False)
        self.resane = resane
        self.q: "queue.Queue[Tuple[str, str, str, str]]" = queue.Queue()
        self.session: Optional[Dict[str, Any]] = None
        self._seq: Dict[str, str] = {}
        self._stop = threading.Event()
        self._httpd = None
        self._threads: List[threading.Thread] = []
        self._last_poll = 0.0
        self._last_alive_check = 0.0
        self._last_clean = 0.0
        self.last_error = ""
        self.saved: List[str] = []

    # ------------------------------------------------------------------ life
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled", True))

    def start(self, http: bool = True) -> None:
        if not self.enabled or self._threads:
            return
        self._stop.clear()
        w = threading.Thread(target=self._worker, name="proof-worker", daemon=True)
        w.start()
        self._threads.append(w)
        if http:
            try:
                handler = _make_handler(self)
                self._httpd = ThreadingHTTPServer(("127.0.0.1", int(self.cfg["port"])), handler)
                self._httpd.daemon_threads = True
                h = threading.Thread(target=self._httpd.serve_forever, name="proof-http", daemon=True)
                h.start()
                self._threads.append(h)
                self.log.log(f"proof: listening on 127.0.0.1:{self.cfg['port']}, folder {self.cfg['dir']}")
            except Exception as e:
                self.last_error = f"HTTP listener failed: {e}"
                self.log.log(f"proof: {self.last_error} (file-signal channel still works)")

    def stop(self) -> None:
        self._stop.set()
        try:
            if self._httpd:
                self._httpd.shutdown()
                self._httpd.server_close()
        except Exception:
            pass
        for th in self._threads:
            if th.name == "proof-worker":
                th.join(timeout=15)
        self._threads = []
        if self.session:                      # never leave a screenrecord running
            try:
                self._finish("watchdog stopping")
            except Exception:
                pass

    def status_text(self) -> str:
        if not self.enabled:
            return "OFF"
        s = self.session
        if s:
            return f"RECORDING {int(time.time() - s['t0'])}s"
        err = f" | last error: {self.last_error}" if self.last_error else ""
        return f"ON (port {self.cfg['port']}, {len(self.saved)} saved this run){err}"

    # ------------------------------------------------------------ public API
    def test(self, target, seconds: int = 6) -> str:
        """Used by the menu: record `seconds` of this clone, return the saved path."""
        before = len(self.saved)
        self.q.put(("start", target.hub_id, "TEST", ""))
        time.sleep(max(2, seconds))
        self.q.put(("done", target.hub_id, "TEST", "completed"))
        for _ in range(60):
            time.sleep(0.5)
            if self.session is None and len(self.saved) > before:
                return self.saved[-1]
        return self.last_error or "no file produced - see watchdog.log"

    # ----------------------------------------------------------------- shell
    def _quiet(self, script: str, timeout: int = 15) -> str:
        """Run a root script without writing it to watchdog.log (used for polling)."""
        cmd = script if self.shell.is_root() else "su -c " + shlex.quote(script)
        try:
            p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
            return (p.stdout or "").strip()
        except Exception:
            return ""
        finally:
            if self.resane:
                self.resane()

    def _recording_pid(self) -> str:
        return self._quiet("pidof screenrecord", timeout=8)

    # ---------------------------------------------------------------- worker
    def _worker(self) -> None:
        self._cleanup_old()
        while not self._stop.is_set():
            try:
                try:
                    ev = self.q.get(timeout=0.25)
                except queue.Empty:
                    ev = None
                if ev:
                    self._handle(*ev)
                self._tick()
            except Exception as e:
                self.last_error = f"{type(e).__name__}: {e}"
                self.log.log(f"proof: worker error {self.last_error}")
                time.sleep(1)

    def _find(self, account: str):
        for t in self.get_targets():
            if account and account in (t.hub_id, t.package, t.label):
                return t
        return None

    def _handle(self, kind: str, account: str, rid: str, result: str = "") -> None:
        t = self._find(account)
        if t is None:
            self.log.log(f"proof: {kind} for unknown account {account!r} ignored")
            return
        now = time.time()
        if kind == "start":
            key = (t.hub_id, rid or "trade")
            s = self.session
            if s is None:
                self._begin(t, key)
            else:
                info = s["ids"].get(key)
                if info is not None and info["done"] is None:
                    return                         # duplicate (HTTP + file)
                s["ids"][key] = {"t": t, "done": None}
                s["stop_at"] = None
                self.log.log(f"proof: {t.label} joined running recording ({key[1]})")
                self._raise(t)
        elif kind == "done":
            s = self.session
            if not s:
                return
            hit = False
            for (acc, r), info in s["ids"].items():
                if acc == t.hub_id and (not rid or r == rid) and info["done"] is None:
                    info["done"] = now
                    info["result"] = (result or "").lower()
                    hit = True
            if hit and all(i["done"] is not None for i in s["ids"].values()):
                s["stop_at"] = now + float(self.cfg["tail_sec"])
                self.log.log(f"proof: {t.label} trade done ({result or 'no result'}); stopping in {self.cfg['tail_sec']}s")

    def _raise(self, t) -> None:
        if not self.cfg.get("bring_to_front", True):
            return
        self.shell.root(
            "monkey -p " + shlex.quote(t.package) +
            " -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1", timeout=15)
        time.sleep(0.8)

    def _begin(self, t, key: Tuple[str, str]) -> None:
        d = str(self.cfg["dir"]).rstrip("/")
        ts = time.strftime("%Y%m%d_%H%M%S")
        tmp = f"{d}/.recording_{ts}.mp4"
        self.log.log(f"proof: START {t.label} ({key[1]})")
        # Start recording FIRST (it returns at once), then raise the clone: the raise
        # takes ~1 s and the decisive moment must not fall into that gap.
        cmd = (
            f"mkdir -p {shlex.quote(d)}; rm -f {shlex.quote(tmp)}; "
            f"nohup screenrecord --time-limit {int(self.cfg['max_sec'])} "
            f"--bit-rate {int(self.cfg['bit_rate'])} {shlex.quote(tmp)} "
            f"</dev/null >/dev/null 2>&1 &"
        )
        self.shell.root(cmd, timeout=15)
        self._raise(t)
        if not self._recording_pid():
            self.last_error = ("screenrecord did not start (try: su -c 'screenrecord "
                               "--time-limit 3 /sdcard/t.mp4')")
            self.log.log("proof: " + self.last_error)
            return
        self.session = {"tmp": tmp, "t0": time.time(), "ts": ts, "stop_at": None,
                        "ids": {key: {"t": t, "done": None}}}

    def _tick(self) -> None:
        now = time.time()
        s = self.session
        if s:
            if s["stop_at"] and now >= s["stop_at"]:
                self._finish("trade ended")
            elif now - s["t0"] > float(self.cfg["max_sec"]) + 3:
                self._finish("max length reached")
            elif now - self._last_alive_check > 3:
                self._last_alive_check = now
                if not self._recording_pid():
                    self._finish("screenrecord ended by itself")
        if self.cfg.get("file_poll", True):
            active = self.session is not None or any(self.is_trading(t) for t in self.get_targets())
            if active and now - self._last_poll >= float(self.cfg["file_poll_sec"]):
                self._last_poll = now
                self._poll_files()
        if now - self._last_clean > 3600:
            self._cleanup_old()

    # -------------------------------------------------------- file channel
    def _poll_files(self) -> None:
        script = ('for f in "/storage/emulated/0"/RobloxClone*/"Arceus X"/Workspace/%s; do '
                  '[ -f "$f" ] && { cat "$f"; echo; }; done' % SIGNAL_FILE)
        out = self._quiet(script, timeout=10)
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            account = str(obj.get("account_id", ""))
            event = str(obj.get("event", "")).lower()
            seq = str(obj.get("seq", ""))
            if event not in ("start", "done") or not account:
                continue
            try:
                ts = float(obj.get("ts", 0) or 0)
            except (TypeError, ValueError):
                ts = 0.0
            last = self._seq.get(account)
            if seq == last:
                continue
            self._seq[account] = seq
            if last is None and (not ts or abs(time.time() - ts) > 10):
                continue                       # old leftover from before we started looking
            if ts and abs(time.time() - ts) > 60:
                continue
            self.q.put((event, account, str(obj.get("request_id", "")), str(obj.get("result", ""))))

    # --------------------------------------------------------------- finish
    def _stop_recording(self) -> None:
        self.shell.root("kill -2 $(pidof screenrecord) 2>/dev/null", timeout=10)   # SIGINT = finalize mp4
        for _ in range(24):
            if not self._recording_pid():
                return
            time.sleep(0.25)
        self.log.log("proof: screenrecord ignored SIGINT, killing it (file may be unplayable)")
        self.shell.root("kill -9 $(pidof screenrecord) 2>/dev/null", timeout=10)

    def _finish(self, reason: str) -> None:
        s = self.session
        self.session = None
        if not s:
            return
        self._stop_recording()
        d = str(self.cfg["dir"]).rstrip("/")
        if (not self.cfg.get("keep_aborted", False)
                and all(i.get("result") == "aborted" for i in s["ids"].values())):
            self.shell.root(f"rm -f {shlex.quote(s['tmp'])}", timeout=15)
            self.log.log("proof: recording discarded (the trade was aborted, nothing to prove)")
            return
        dests: List[Tuple[str, Any, str]] = []
        for (acc, rid), info in s["ids"].items():
            t = info["t"]
            res = _safe(info.get("result") or "", 12) if info.get("result") else ""
            dests.append((rid, t, f"{d}/{_safe(rid)}_{_safe(t.label, 24)}_{s['ts']}" + (f"_{res}" if res else "") + ".mp4"))
        keep = int(self.cfg.get("keep_last_sec", 0) or 0)
        ff = str(self.cfg.get("ffmpeg", ""))
        lines = [f"src={shlex.quote(s['tmp'])}",
                 '[ -s "$src" ] || { echo PROOF_EMPTY; exit 1; }']
        if keep > 0 and ff:
            lines.append(
                f'if [ -x {shlex.quote(ff)} ]; then '
                f'LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib {shlex.quote(ff)} -y -loglevel error '
                f'-sseof -{keep} -i "$src" -c copy "$src.trim.mp4" </dev/null >/dev/null 2>&1 '
                f'&& [ -s "$src.trim.mp4" ] && mv -f "$src.trim.mp4" "$src"; rm -f "$src.trim.mp4"; fi')
        first = dests[0][2]
        lines.append(f'mv -f "$src" {shlex.quote(first)} || exit 2')
        for _, _, p in dests[1:]:
            lines.append(f"cp -f {shlex.quote(first)} {shlex.quote(p)}")
        lines.append(f'chmod 644 {shlex.quote(d)}/*.mp4 2>/dev/null; echo PROOF_OK $(wc -c < {shlex.quote(first)})')
        r = self.shell.root("; ".join(lines), timeout=90)
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(r"PROOF_OK (\d+)", out)
        if not m:
            self.last_error = "saving the video failed: " + (out.strip()[-160:] or f"rc={r.returncode}")
            self.log.log("proof: " + self.last_error)
            return
        self.log.log(f"proof: SAVED ({reason}, {int(m.group(1)) // 1024} KB): " +
                     ", ".join(p for _, _, p in dests))
        for rid, t, p in dests:
            self.saved.append(p)
            self.saved = self.saved[-50:]
            if self.on_saved:
                try:
                    self.on_saved(t, rid, p)
                except Exception as e:
                    self.log.log(f"proof: on_saved callback failed: {e}")

    def _cleanup_old(self) -> None:
        self._last_clean = time.time()
        d = shlex.quote(str(self.cfg["dir"]).rstrip("/"))
        days = max(1, int(self.cfg.get("keep_days", 14) or 14))
        self._quiet(f"[ -d {d} ] && {{ find {d} -name '*.mp4' -mtime +{days} -delete; "
                    f"find {d} -name '.recording_*' -mmin +120 -delete; }}", timeout=30)


def _make_handler(rec: ProofRecorder):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_a):          # keep the terminal / log quiet
            pass

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)

            def g(k: str) -> str:
                return (q.get(k) or [""])[0]

            code, body = 200, b"ok"
            if u.path in ("/proof/start", "/proof/done"):
                rec.q.put((u.path.rsplit("/", 1)[1], g("account"), g("id"), g("result")))
            elif u.path != "/proof/ping":
                code, body = 404, b"not found"
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


class Watchdog:
    NOT_RUNNING_CONFIRM_TICKS = 3

    # --- crash-restart tuning (only used when crash-restart is ON) ----------
    GRACE_AFTER_LAUNCH_SEC = 240          # no health checks this long after a launch
    CONFIRM_BAD_TICKS = 2                 # must look bad this many checks in a row
    MIN_GAP_BETWEEN_CRASH_RESTARTS = 45   # seconds between crash restarts, any clone
    MIN_HUNG_SEC = 300                    # zero CPU change this long before "hung"
    # --- launch spacing ------------------------------------------------------
    LAUNCH_STAGGER_SEC = 8                # min seconds between any two cold starts
    # --- zombie (process alive, no Activity) detection -----------------------
    ZOMBIE_CONFIRM_TICKS = 3              # consecutive checks with no Activity
    ZOMBIE_GRACE_SEC = 90                 # don't judge a clone this soon after launch
    # --- hub transition queue / Termux protection (v3.8) ---------------------
    TRANSITION_GAP_SEC = 20               # min seconds between queued TRADING/FARMING switches
    PROTECT_EVERY_SEC = 60                # how often to re-apply Termux oom protection
    ACTIVITY_CACHE_SEC = 8                # share one dumpsys across clones

    def __init__(
        self,
        targets: List[Target],
        interval_sec: int,
        hang_sec: int,
        trading_share_link: str,
        hub_url: str,
        hub_token: str,
        hub_poll_sec: int,
        logger: Logger,
        crash_restart_enabled: bool = False,
        focus_handoff: bool = False,
        soft_return: bool = False,
        autoexec: Optional[dict] = None,
        proof: Optional[dict] = None,
        hubcfg: Optional[dict] = None,
    ):
        self.targets = targets
        self.interval_sec = max(5, int(interval_sec))
        self.hang_sec = max(15, int(hang_sec))
        self.trading_share_link = trading_share_link or DEFAULT_TRADING_SHARE_LINK
        self.log = logger
        self.shell = Shell(logger)
        self.detector = Detector(self.shell)
        self.controller = Controller(self.shell, logger)
        self.hub = HubClient(hub_url, hub_token, logger)
        self.hub_poll_sec = max(1, int(hub_poll_sec or DEFAULT_HUB_POLL_SEC))
        self.crash_restart_enabled = crash_restart_enabled
        self.running = False
        self.next_hub_poll = 0.0
        self.last_crash_restart = 0.0
        self.last_launch_any = 0.0
        self.focus_handoff = focus_handoff
        self.soft_return = soft_return
        self.pending_transitions: List[Tuple[Target, str]] = []
        self.last_protect = 0.0
        self._last_protect_out = ""
        self._wakelock_done = False
        self.pending_snapshots: List[Tuple[float, str, int]] = []
        self._act_cache: Tuple[float, Optional[set]] = (0.0, None)
        self.autoexec = AutoexecInstaller(self.shell, logger, autoexec)
        self.hubcfg = HubConfigInstaller(self.shell, logger, hubcfg, self.autoexec.clone_name_for,
                                         lambda t: resolve_sea(t, getattr(t, "_hub_sea", 0)),
                                         lambda script, timeout: self._rec_shell(script, timeout=timeout))
        try:
            self.headless = not sys.stdout.isatty()
        except Exception:
            self.headless = True
        self.proof = None
        pc = {**DEFAULT_PROOF, **(proof or {})}
        if pc.get("enabled", True):
            self.proof = ProofRecorder(
                self.shell, logger, lambda: self.targets, pc,
                on_saved=self._proof_saved,
                is_trading=lambda t: t.hub_state == "TRADING",
                resane=_resane_tty,
            )

    def _proof_saved(self, t: Target, rid: str, path: str) -> None:
        self.log.log(f"{t.label}: proof video saved: {path}")
        self.notify(t, t.status, "proof_saved", {"request_id": rid, "file": path})

    def ensure_autoexec(self, t: Target, force: bool = False) -> None:
        """Best-effort and cheap (re-checks a clone at most every few minutes): never blocks a launch."""
        try:
            self.autoexec.ensure(t, self.targets, force=force)
        except Exception as e:
            self.log.log(f"{t.label}: autoexec check failed: {e}")

    def ensure_hubcfg(self, t: Target) -> None:
        """Call right after a clone was force-stopped and before it is launched. Best-effort, never raises."""
        try:
            self.hubcfg.apply(t, self.targets)
        except Exception as e:
            self.log.log(f"{t.label}: hub config check failed: {e}")

    HUBCFG_FIRST_GRACE_SEC = 90       # the hub needs this long after a launch to create its folder and file
    HUBCFG_CHECK_EVERY_SEC = 60

    def check_hubcfg_pending(self, t: Target) -> bool:
        """A clone whose hub file did not exist at its last launch: once the file shows up, restart the clone ONCE so it loads
        the template. Returns True if it restarted the clone."""
        if not (self.hubcfg.enabled and getattr(t, "_hubcfg_pending", False)) or t.hub_state == "TRADING":
            return False
        now = time.time()
        if not t.last_launch or now - t.last_launch < self.HUBCFG_FIRST_GRACE_SEC:
            return False
        if now - getattr(t, "_hubcfg_checked", 0.0) < self.HUBCFG_CHECK_EVERY_SEC:
            return False
        t._hubcfg_checked = now
        try:
            found, differs = self.hubcfg.pending_check(t, self.targets)
        except Exception as e:
            self.log.log(f"{t.label}: hub config check failed: {e}")
            return False
        if found == 0:
            return False
        t._hubcfg_pending = False              # the file exists now: this check is done either way
        if differs == 0:
            self.log.log(f"{t.label}: hub config file appeared and already matches; nothing to do")
            return False
        if now - self.last_launch_any < self.LAUNCH_STAGGER_SEC:
            t._hubcfg_pending = True           # another clone is starting right now: try again next time
            return False
        self.log.log(f"{t.label}: the hub created its config file on the first launch; restarting this clone once to load the template")
        self.restart(t, "first launch: loading the Quantum config")
        return True

    SEA_SWITCH_DEBOUNCE_SEC = 120     # the Hub must report the new sea this long without interruption
    SEA_SWITCH_MIN_UPTIME_SEC = 300   # never restart a clone that was launched less than this long ago
    SEA_SWITCH_COOLDOWN_SEC = 1800    # at most one such restart per clone per this long

    @staticmethod
    def _cfg_group(sea: int) -> int:
        return 1 if int(sea or 0) == 1 else 2        # Sea 3 uses the Sea 2 config

    def check_sea_switch(self, t: Target) -> bool:
        """The clone's config was written for one sea but the Hub now says it is in the other: restart it once so the hub script loads
        the right file. Only the Hub's word counts (not the Place ID). Returns True if it restarted the clone."""
        if not self.hubcfg.enabled or not self.hubcfg.cfg.get("restart_on_sea_change", True):
            return False
        applied = int(getattr(t, "_hubcfg_sea", 0) or 0)
        hub_sea = int(getattr(t, "_hub_sea", 0) or 0)
        if applied not in (1, 2, 3) or hub_sea not in (1, 2, 3) or getattr(t, "_hubcfg_pending", False):
            t._sea_seen_since = 0.0
            return False
        if self._cfg_group(hub_sea) == self._cfg_group(applied):
            t._sea_seen_since = 0.0
            return False
        now = time.time()
        if not getattr(t, "_sea_seen_since", 0.0):
            t._sea_seen_since = now                      # first moment the Hub disagrees with the applied config
            return False
        if t.hub_state == "TRADING" or now - t._sea_seen_since < self.SEA_SWITCH_DEBOUNCE_SEC:
            return False
        if not t.last_launch or now - t.last_launch < self.SEA_SWITCH_MIN_UPTIME_SEC:
            return False
        if now - getattr(t, "_sea_switch_at", 0.0) < self.SEA_SWITCH_COOLDOWN_SEC:
            return False
        if now - self.last_launch_any < self.LAUNCH_STAGGER_SEC:
            return False
        t._sea_switch_at = now
        t._sea_seen_since = 0.0
        self.log.log(f"{t.label}: the Hub says Sea {hub_sea}, the Quantum config on it is for Sea {applied}; restarting once to load the right one")
        self.restart(t, f"Sea {applied} -> {hub_sea}: loading the matching Quantum config")
        return True

    def mode(self, t: Target) -> str:
        return "TRADING" if t.hub_state == "TRADING" else "FARMING"

    # ------------------------------------------------------------------
    # Flight recorder
    # ------------------------------------------------------------------
    def rec_write(self, text: str) -> None:
        try:
            try:
                if os.path.getsize(RECORDER_PATH) > RECORDER_MAX_BYTES:
                    os.replace(RECORDER_PATH, RECORDER_PATH + ".1")
            except OSError:
                pass
            with open(RECORDER_PATH, "a", encoding="utf-8") as f:
                f.write(text.rstrip() + "\n")
        except Exception:
            pass

    def _rec_shell(self, script: str, timeout: int = 40, with_err: bool = True) -> str:
        """Run a root script WITHOUT writing it (or its output) to watchdog.log."""
        cmd = script if self.shell.is_root() else "su -c " + shlex.quote(script)
        try:
            p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
            err = (("\nERR " + p.stderr.strip()[-300:]) if (with_err and p.stderr.strip()) else "")
            return (p.stdout or "").strip() + err
        except subprocess.TimeoutExpired:
            return f"(snapshot timed out after {timeout}s)"
        except Exception as e:
            return f"(snapshot failed: {e})"
        finally:
            _resane_tty()

    def snapshot(self, tag: str, stage: str, extra_events: bool = False) -> None:
        script = (
            'echo "-- top activity"; '
            'dumpsys activity activities 2>/dev/null | grep -m4 -E "topResumedActivity|ResumedActivity|mFocusedApp"; '
            'echo "-- window focus"; '
            'dumpsys window 2>/dev/null | grep -m3 -E "mCurrentFocus|mFocusedApp"; '
            'echo "-- processes (PID ETIME NAME)"; '
            '(ps -A -o PID,ETIME,NAME 2>/dev/null || ps -A 2>/dev/null) | '
            'grep -E "system_server|og\\.launcher|com\\.termux|com\\.roblox"; '
            'echo "-- memory"; grep -E "MemTotal|MemAvailable" /proc/meminfo'
        )
        if extra_events:
            script += (
                '; echo "-- recent kills / deaths / starts (logcat events)"; '
                'logcat -b events -d -t 800 2>/dev/null | grep -E "am_kill|am_proc_died|am_proc_start" | '
                'grep -E "og\\.launcher|com\\.termux|com\\.roblox" | tail -30'
            )
        out = self._rec_shell(script)
        states = ", ".join(f"{x.package.split('.')[-1]}={x.status}" for x in self.targets if x.enabled)
        self.rec_write(f"===== {now_str()}  {tag}  [{stage}] =====\nwatchdog view: {states}\n{out}\n")

    def schedule_snapshots(self, tag: str) -> None:
        now = time.time()
        for d in SNAPSHOT_DELAYS:
            self.pending_snapshots.append((now + d, tag, d))
        self.pending_snapshots = self.pending_snapshots[-60:]

    def run_due_snapshots(self) -> None:
        """Run at most one overdue snapshot per call, so the main loop never stalls."""
        now = time.time()
        for i, (due, tag, d) in enumerate(self.pending_snapshots):
            if due <= now:
                self.pending_snapshots.pop(i)
                self.snapshot(tag, f"T+{d}s (ran {int(now - due)}s late)" if now - due > 2 else f"T+{d}s",
                              extra_events=(d >= 20))
                return

    def prepare_stop(self, t: Target, tag: str) -> None:
        """Called right before a clone is force-stopped."""
        full_tag = f"{t.label} {tag}"
        self.snapshot(full_tag, "T-0 (before force-stop)")
        self.schedule_snapshots(full_tag)
        if self.focus_handoff:
            # Experimental: make sure the clone about to die is not the focused window.
            self.log.log(f"{t.label}: focus handoff -> Termux before force-stop")
            self.shell.root("am start -n com.termux/.app.TermuxActivity", timeout=10)
            time.sleep(1.0)

    # ------------------------------------------------------------------
    # v4.0: crash forensics + safe drawing
    # ------------------------------------------------------------------
    def touch_alive(self) -> None:
        try:
            tmp = ALIVE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"pid": os.getpid(), "ts": time.time()}, f)
            os.replace(tmp, ALIVE_PATH)
        except Exception:
            pass

    def clear_alive(self) -> None:
        try:
            with open(ALIVE_PATH, encoding="utf-8") as f:
                if json.load(f).get("pid") == os.getpid():
                    os.remove(ALIVE_PATH)
        except Exception:
            pass

    def post_mortem(self) -> None:
        """If the previous run left watchdog.alive behind, it was killed from outside."""
        try:
            with open(ALIVE_PATH, encoding="utf-8") as f:
                prev = json.load(f)
        except Exception:
            return
        if prev.get("pid") == os.getpid():
            return
        try:
            ago = int(time.time() - float(prev.get("ts", 0)))
        except Exception:
            ago = -1
        self.log.log(f"PREVIOUS RUN DIED UNCLEANLY: pid {prev.get('pid')} was last alive {ago}s ago "
                     f"(no 'Watchdog stopped' line = killed by Android/SIGKILL). Details: flight_recorder.log")
        out = self._rec_shell(
            'echo "-- kills/deaths mentioning termux or python (logcat events)"; '
            'logcat -b events -d -t 5000 2>/dev/null | grep -E "am_kill|am_proc_died|am_low_memory" | '
            'grep -iE "termux|python" | tail -15; '
            'echo "-- lmkd / system"; logcat -b system -d -t 4000 2>/dev/null | grep -iE "lmkd|killing" | tail -10; '
            'echo "-- kernel"; dmesg 2>/dev/null | grep -iE "lowmemory|oom|killed process" | tail -5',
            timeout=60)
        self.rec_write(f"===== {now_str()}  POST-MORTEM of pid {prev.get('pid')} (last alive {ago}s earlier) =====\n{out}\n")

    def guard(self, name: str, fn, *args) -> None:
        """Run one start-up step; log and survive any exception."""
        try:
            fn(*args)
        except Exception as e:
            self.log.log(f"startup step '{name}' failed (continuing): {type(e).__name__}: {e}")
            self.log.log(traceback.format_exc()[-1500:])

    def draw(self) -> None:
        text = self.render()
        try:                                   # always keep a copy for `rw.py watch`
            tmp = SCREEN_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            os.replace(tmp, SCREEN_PATH)
        except Exception:
            pass
        if self.headless:
            return
        try:
            clear_screen()
            print(text)
            sys.stdout.flush()
        except Exception as e:
            self.headless = True
            self.log.log(f"terminal output lost ({type(e).__name__}); continuing headless "
                         f"(view with: python3 rw.py watch)")

    def activity_packages(self) -> Optional[set]:
        """Packages that currently own at least one Activity record, or None if unknown."""
        ts, cached = self._act_cache
        if time.time() - ts < self.ACTIVITY_CACHE_SEC:
            return cached
        out = self._rec_shell(
            "dumpsys activity activities 2>/dev/null | "
            "grep -oE 'ActivityRecord[{][0-9a-f]+ u[0-9]+ [A-Za-z0-9_.]+/' | sort -u",
            timeout=30, with_err=False,
        )
        pkgs = set()
        for line in out.splitlines():
            m = re.search(r" u\d+ ([A-Za-z0-9_.]+)/", line)
            if m:
                pkgs.add(m.group(1))
        result = pkgs or None
        self._act_cache = (time.time(), result)
        return result

    def check_zombie(self, t: Target) -> bool:
        """True once a clone has had a process but no Activity for ZOMBIE_CONFIRM_TICKS checks."""
        if t.last_launch and time.time() - t.last_launch < self.ZOMBIE_GRACE_SEC:
            t._zombie_ticks = 0
            return False
        pkgs = self.activity_packages()
        if pkgs is None:
            return False                      # dump unusable: unknown, never act on it
        if not any(x.package in pkgs for x in self.targets if x.enabled):
            return False                      # no clone shows an Activity: can't validate the dump
        if t.package in pkgs:
            t._zombie_ticks = 0
            return False
        t._zombie_ticks = getattr(t, "_zombie_ticks", 0) + 1
        return t._zombie_ticks >= self.ZOMBIE_CONFIRM_TICKS

    def stagger_offset(self, t: Target) -> float:
        """How much earlier than a full interval this clone's first rejoin falls.

        Clone k (0-based, among enabled clones) of N gets k/N of an interval, so
        deadlines are spread evenly instead of all landing at the same moment.
        """
        enabled = [x for x in self.targets if x.enabled]
        if t not in enabled or t.rejoin_interval_min <= 0 or len(enabled) < 2:
            return 0.0
        k = enabled.index(t)
        return (k / len(enabled)) * t.rejoin_interval_min * 60

    def adopt(self, t: Target) -> None:
        """Start a clone's rejoin timer WITHOUT restarting it."""
        t.last_rejoin = time.time() - self.stagger_offset(t)

    def adopt_running_targets(self) -> None:
        for t in self.targets:
            if t.enabled and t.last_rejoin == 0 and self.controller.is_running(t.package):
                self.adopt(t)
                self.log.log(f"{t.label}: already running at startup; adopted without restarting")

    def heartbeat(self, t: Target) -> None:
        if not self.hub.enabled:
            return
        try:
            self.hub.heartbeat(t, t.status, self.mode(t))
            t.last_heartbeat = time.time()
            t.hub_error = ""
        except Exception as e:
            t.hub_error = str(e)
            self.log.log(f"{t.label}: hub heartbeat failed: {e}")

    def notify(self, t: Target, status: str, event: str, extra: Optional[Dict[str, Any]] = None) -> None:
        if not self.hub.enabled:
            return
        try:
            self.hub.event(t, status, event, extra)
        except Exception as e:
            t.hub_error = str(e)
            self.log.log(f"{t.label}: hub event failed: {e}")

    def sync_localtrader_config(self, target: Optional[Target] = None) -> None:
        """Write Hub credentials + per-account mode into the clone Workspace.

        Best-effort by design: every caller (restart(), poll_hub()'s
        enter_trading()/return_to_farming() dispatch, run()) depends on this
        never raising. poll_hub() in particular updates t.hub_state BEFORE
        calling this - if this threw there, the state-change dispatch below
        it would be skipped, and since t.hub_state already matches the new
        value, the next poll wouldn't detect a "change" either, silently and
        permanently dropping the transition. So the whole body is guarded;
        a failure here (bad Hub data, missing Workspace, a denied su prompt)
        is logged and swallowed, never allowed to block a caller.
        """
        if not self.hub.enabled:
            return
        try:
            self._sync_localtrader_config_inner(target)
        except Exception as e:
            label = target.label if target else "all clones"
            self.log.log(f"{label}: LocalTrader config sync failed: {e}")

    def _sync_localtrader_config_inner(self, target: Optional[Target] = None) -> None:
        if target is not None:
            clone_name = target.clone_folder
            if not clone_name:
                m = re.search(r"RobloxClone\d+", target.label or "")
                clone_name = m.group(0) if m else ""
            if not clone_name:
                try:
                    ordinal = self.targets.index(target) + 1
                except ValueError:
                    ordinal = 1
                clone_name = f"RobloxClone{ordinal:03d}"
            target.clone_folder = clone_name
            workspace = f"/storage/emulated/0/{clone_name}/Arceus X/Workspace"
        else:
            workspace = "/storage/emulated/0/RobloxClone*/Arceus X/Workspace"

        # This file is the local bridge from rw.py -> LocalTrader.  rw.py
        # already receives the complete request from Hub via /poll/<account>.
        # Keep the order data in the Workspace JSON so LocalTrader does not
        # need to perform a second Hub lookup or map Roblox UserId -> account.
        request = {}
        if target is not None:
            try:
                request = getattr(target, "hub_request", {}) or {}
            except Exception:
                request = {}

        payload = json.dumps({
            "version": 3,
            "hub_url": self.hub.base_url,
            "hub_token": self.hub.token,
            "hub_poll_sec": self.hub_poll_sec,
            "mode": "TRADING" if target and target.hub_state == "TRADING" else "FARMING",
            "account_id": target.hub_id if target else "",
            "request_id": str(request.get("request_id", "")) if isinstance(request, dict) else "",
            "customer": str(request.get("customer", "")) if isinstance(request, dict) else "",
            "item": str(request.get("item", "")) if isinstance(request, dict) else "",
            "quantity": max(1, int(request.get("quantity", 1) or 1)) if isinstance(request, dict) else 1,
            "request_status": str(request.get("status", "")) if isinstance(request, dict) else "",
            "proof_enabled": bool(self.proof),
            "proof_url": f"http://127.0.0.1:{self.proof.cfg['port']}" if self.proof else "",
        }, ensure_ascii=False, separators=(",", ":"))
        encoded = base64.b64encode(payload.encode("utf-8")).decode("ascii")

        if target is not None:
            workspace_q = shlex.quote(workspace)
            cmd = (
                "d=" + workspace_q + "; "
                "[ -d \"$d\" ] || { "
                "echo " + shlex.quote(f"Workspace does not exist: {workspace}") + " >&2; exit 2; }; "
                "tmp=\"$d/." + LOCALTRADER_CONFIG_NAME + ".tmp\"; "
                "echo " + shlex.quote(encoded) + " | base64 -d > \"$tmp\" && "
                "mv -f \"$tmp\" \"$d/" + LOCALTRADER_CONFIG_NAME + "\""
            )
        else:
            cmd = (
                "for d in /storage/emulated/0/RobloxClone*/Arceus X/Workspace; do "
                "[ -d \"$d\" ] || continue; "
                "tmp=\"$d/." + LOCALTRADER_CONFIG_NAME + ".tmp\"; "
                "echo " + shlex.quote(encoded) + " | base64 -d > \"$tmp\" && "
                "mv -f \"$tmp\" \"$d/" + LOCALTRADER_CONFIG_NAME + "\"; done"
            )

        # redact=True: the command line contains the Hub token (base64), so
        # it must not be written to watchdog.log.
        result = self.shell.root(cmd, timeout=15, redact=True)
        if result.returncode != 0:
            self.log.log(f"{target.label if target else 'all clones'}: LocalTrader config sync failed: {result.stderr.strip()[:500]}")
        else:
            self.log.log(f"{target.label if target else 'all clones'}: LocalTrader_Hub.json synced")

    def poll_hub(self) -> None:
        if not self.hub.enabled:
            return
        now = time.time()
        if now < self.next_hub_poll:
            return
        self.next_hub_poll = now + self.hub_poll_sec
        for t in self.targets:
            if not t.enabled:
                continue
            try:
                data = self.hub.poll(t)
                desired = str(data.get("desired_state", "FARMING")).upper()
                if desired not in ("FARMING", "TRADING"):
                    desired = "FARMING"
                version = int(data.get("version", 0) or 0)
                req = data.get("request") or {}
                t.hub_request = req if isinstance(req, dict) else {}
                try:
                    t._hub_sea = int(data.get("sea", 0) or 0)      # hub.py v2.9.5+; older hubs send nothing
                except (TypeError, ValueError):
                    t._hub_sea = 0
                if (not t._hub_sea and self.hubcfg.enabled and t.last_launch and time.time() - t.last_launch > 600
                        and time.time() - getattr(t, "_nosea_logged", 0.0) > 1800):
                    t._nosea_logged = time.time()
                    self.log.log(f"{t.label}: the Hub reports NO sea for account {t.hub_id} - the Sea 1/Sea 2 config switch cannot work. "
                                 f"Either hub.py is older than v2.9.5 (or was not restarted), or the in-game script reports under a "
                                 f"different account id (relaunch the clone after a device-id change), or LocalTrader does not send the sea.")
                t.hub_request_id = str(req.get("request_id", "")) if isinstance(req, dict) else ""

                # Keep LocalTrader_Hub.json current even when only the request
                # contents changed while desired_state/version stayed the same.
                request_changed = (
                    isinstance(req, dict)
                    and str(req.get("request_id", "")) != str(getattr(t, "_synced_request_id", ""))
                )

                if version != t.hub_version or desired != t.hub_state:
                    old = t.hub_state
                    t.hub_version = version
                    t.hub_state = desired
                    self.log.log(
                        f"{t.label}: hub desired state {old} -> {desired}"
                        + (f" request={t.hub_request_id}" if t.hub_request_id else "")
                    )
                    # LocalTrader reads this file from the clone Workspace.
                    # Write the NEW state before launching/restarting Roblox so
                    # LocalTrader never starts with stale FARMING/TRADING mode.
                    self.sync_localtrader_config(t)
                    # v3.8: queue the transition instead of running it right
                    # here, so clones switch one at a time instead of all
                    # force-stopping and cold-starting together.
                    if desired == "TRADING" and old != "TRADING":
                        self.queue_transition(t, "enter_trading")
                    elif desired == "FARMING" and old == "TRADING":
                        self.queue_transition(t, "return_to_farming")
                    t._synced_request_id = t.hub_request_id
                elif request_changed:
                    self.sync_localtrader_config(t)
                    t._synced_request_id = t.hub_request_id
                t.hub_error = ""
            except Exception as e:
                t.hub_error = str(e)
                self.log.log(f"{t.label}: hub poll failed: {e}")

    # ------------------------------------------------------------------
    # v3.8: one-at-a-time transitions + Termux protection
    # ------------------------------------------------------------------
    def queue_transition(self, t: Target, kind: str) -> None:
        self.pending_transitions = [x for x in self.pending_transitions if x[0] is not t]
        self.pending_transitions.append((t, kind))
        self.log.log(f"{t.label}: {kind} queued (position {len(self.pending_transitions)})")

    def run_pending_transition(self) -> None:
        """Run at most one queued transition, and only if the last launch was long enough ago."""
        if not self.pending_transitions:
            return
        if time.time() - self.last_launch_any < self.TRANSITION_GAP_SEC:
            return
        t, kind = self.pending_transitions.pop(0)
        # Drop stale requests: the Hub may have changed its mind while we waited.
        if kind == "enter_trading" and t.hub_state == "TRADING":
            self.enter_trading(t)
        elif kind == "return_to_farming" and t.hub_state == "FARMING":
            self.return_to_farming(t)
        else:
            self.log.log(f"{t.label}: queued {kind} dropped (state changed)")

    def protect_termux(self, force: bool = False) -> None:
        """Make the low-memory killer prefer anything except Termux and this script."""
        now = time.time()
        if not force and now - self.last_protect < self.PROTECT_EVERY_SEC:
            return
        self.last_protect = now
        me = os.getpid()
        out = self._rec_shell(
            f'for p in $(pidof com.termux) {me}; do '
            'echo -900 > /proc/$p/oom_score_adj 2>/dev/null; '
            'echo "pid $p oom_score_adj=$(cat /proc/$p/oom_score_adj 2>/dev/null)"; done',
            timeout=20, with_err=False,
        )
        if out != self._last_protect_out:
            self._last_protect_out = out
            self.log.log("Termux oom protection: " + out.replace("\n", "; "))
        if not self._wakelock_done:
            self._wakelock_done = True
            extra = self._rec_shell(
                'cmd deviceidle whitelist +com.termux 2>&1 | head -1; '
                'echo rw_watchdog > /sys/power/wake_lock 2>/dev/null && echo "kernel wake lock held"',
                timeout=20, with_err=False)
            self.log.log("power settings: " + extra.replace("\n", "; "))
            try:
                subprocess.run(["termux-wake-lock"], timeout=10, capture_output=True)
                self.log.log("termux-wake-lock requested")
            except Exception as e:
                self.log.log(f"termux-wake-lock unavailable: {e}")
            finally:
                _resane_tty()

    def enter_trading(self, t: Target) -> None:
        if not t.enabled:
            return
        self.ensure_autoexec(t)
        self.sync_localtrader_config(t)
        self.log.log(f"{t.label}: ENTER TRADING")
        t.status = "switching_to_trading"
        self.notify(t, t.status, "enter_trading", {"request_id": t.hub_request_id})
        self.prepare_stop(t, "ENTER_TRADING")
        self.controller.force_stop(t)
        time.sleep(1)
        ok = self.controller.launch_trading(t, self.trading_share_link)
        self.last_launch_any = time.time()
        t.trading_join_attempted = True
        if ok:
            t.status = "trading_joining"
            t.fail_streak = 0
            self.log.log(f"{t.label}: trading deep link sent")
            self.notify(t, t.status, "trading_deep_link_sent", {"request_id": t.hub_request_id})
        else:
            t.status = "error"
            t.fail_streak += 1
            self.notify(t, t.status, "trading_deep_link_failed", {"request_id": t.hub_request_id})

    def return_to_farming(self, t: Target) -> None:
        self.ensure_autoexec(t)
        self.sync_localtrader_config(t)
        self.log.log(f"{t.label}: RETURN TO FARMING")
        t.status = "switching_to_farming"
        self.notify(t, t.status, "return_to_farming")
        if self.soft_return and self.controller.is_running(t.package):
            self.log.log(f"{t.label}: soft return (no force-stop; farming link sent into running clone)")
            full_tag = f"{t.label} RETURN_TO_FARMING (soft)"
            self.snapshot(full_tag, "T-0 (soft, no force-stop)")
            self.schedule_snapshots(full_tag)
        else:
            self.prepare_stop(t, "RETURN_TO_FARMING")
            self.controller.force_stop(t)
            self.ensure_hubcfg(t)
            time.sleep(1)
        ok = self.controller.launch(t)
        self.last_launch_any = time.time()
        t.trading_join_attempted = False
        if ok:
            t.status = "launching"
            t.last_rejoin = time.time()
            self.notify(t, t.status, "farming_launch_sent")
        else:
            t.status = "error"
            t.fail_streak += 1

    def cpu_ticks(self, pid: str) -> Optional[int]:
        out = self.shell.root_out(f"cat /proc/{shlex.quote(pid)}/stat 2>/dev/null", timeout=15)
        m = re.search(r"\)\s+\S+\s+(.*)", out)
        if not m:
            return None
        fields = m.group(1).split()
        try:
            return int(fields[10]) + int(fields[11])
        except (IndexError, ValueError):
            return None

    def error_dialog(self, package: str) -> bool:
        """True only if a crash/ANR dialog naming THIS package is on screen.

        The old version grepped all of `dumpsys window` with no package
        filter, so a match from any window made every clone look crashed.
        """
        pat = re.escape(package) + r"([^A-Za-z0-9_.]|$)"
        out = self.shell.root_out(
            "dumpsys window 2>/dev/null | grep -iE "
            "'Application Error|Application Not Responding' | grep -E "
            + shlex.quote(pat),
            timeout=25,
        )
        return bool(out.strip())

    def wake(self) -> None:
        out = self.shell.root_out(
            "dumpsys power 2>/dev/null | grep -m1 -E 'mWakefulness|Display Power'",
            timeout=20,
        )
        if any(s in out for s in ("Asleep", "Dozing", "state=OFF")):
            self.shell.root("input keyevent KEYCODE_WAKEUP", timeout=15)
            time.sleep(0.6)
            self.shell.root("input keyevent KEYCODE_MENU", timeout=15)

    def health(self, t: Target) -> str:
        pid = self.controller.pid(t.package)
        if not pid:
            return "dead"
        now = time.time()

        # Still loading after a launch: don't judge it yet.
        if t.last_launch and now - t.last_launch < self.GRACE_AFTER_LAUNCH_SEC:
            t.last_cpu = None
            t._stale_since = 0.0
            t._bad_ticks = 0
            return "ok"

        bad = None
        if self.error_dialog(t.package):
            bad = "dialog"
        else:
            ticks = self.cpu_ticks(pid)
            if ticks is not None:
                if t.last_cpu is not None and ticks <= t.last_cpu:
                    if not getattr(t, "_stale_since", 0.0):
                        t._stale_since = now
                    if now - t._stale_since >= max(self.hang_sec, self.MIN_HUNG_SEC):
                        bad = "hung"
                else:
                    t._stale_since = 0.0
                t.last_cpu = ticks

        if bad:
            t._bad_ticks = getattr(t, "_bad_ticks", 0) + 1
            return bad if t._bad_ticks >= self.CONFIRM_BAD_TICKS else "ok"
        t._bad_ticks = 0
        return "ok"

    def restart(self, t: Target, reason: str) -> None:
        if time.time() < t.cooldown_until:
            return
        first_launch = (t.last_rejoin == 0)
        # restart() relaunches in the clone's CURRENT hub mode, so it already
        # completes any queued TRADING/FARMING transition for this clone.
        self.pending_transitions = [x for x in self.pending_transitions if x[0] is not t]
        t.restarts += 1
        t.fail_streak += 1
        self.log.log(f"{t.label}: restart #{t.restarts}: {reason}")
        t.status = "restarting"
        self.notify(t, t.status, "restart", {"reason": reason})
        # Always rewrite the Workspace config right before relaunching, not just on
        # a Hub-triggered enter_trading()/return_to_farming(). restart() is also
        # called from tick() for crash recovery, scheduled rejoins, and the initial
        # launch - none of which otherwise touch this file. Without this, the game
        # can relaunch (e.g. via its own post-trade TeleportService call, ahead of
        # our own poll_hub() cycle) while LocalTrader_Hub.json still holds a stale
        # mode from before, and the in-game startup notice reports the wrong state
        # even though t.hub_state itself is current.
        # sync_localtrader_config() is itself exception-safe (see its docstring),
        # so this can never block the relaunch below it.
        self.ensure_autoexec(t)
        self.sync_localtrader_config(t)
        self.wake()
        self.prepare_stop(t, f"RESTART ({reason})")
        self.controller.force_stop(t)
        self.ensure_hubcfg(t)
        time.sleep(2.5)
        if t.hub_state == "TRADING":
            ok = self.controller.launch_trading(t, self.trading_share_link)
        else:
            ok = self.controller.launch(t)
            t.last_rejoin = time.time()
            if first_launch:
                # spread the first rejoin deadline so clones don't all come due together
                t.last_rejoin -= self.stagger_offset(t)
        self.last_launch_any = time.time()
        t.last_cpu = None
        t.stale_ticks = 0
        t.not_running_ticks = 0
        if ok:
            t.status = "launching" if t.hub_state == "FARMING" else "trading_joining"
            t.fail_streak = 0
        else:
            t.status = "error"
            t.cooldown_until = time.time() + min(300, 30 * (2 ** min(t.fail_streak, 4)))

    def inspect_process(self, t: Target) -> Tuple[bool, str]:
        pid = self.controller.pid(t.package)
        if not pid:
            return False, "not running"
        return True, pid

    def tick(self, t: Target) -> None:
        if not t.enabled:
            t.status = "disabled"
            return

        if time.time() < t.cooldown_until:
            t.status = "cooldown"
            return

        t._pid = self.controller.pid(t.package)
        running = bool(t._pid)

        # A clone that is running but whose timer was never started (it appeared
        # after startup, e.g. you opened it by hand) is adopted, not restarted.
        if running and t.last_rejoin == 0:
            self.adopt(t)
            self.log.log(f"{t.label}: running with no rejoin timer; adopted without restarting")

        now = time.time()
        due = t.rejoin_interval_min > 0 and (
            t.last_rejoin == 0 or now - t.last_rejoin >= t.rejoin_interval_min * 60
        )

        # Log every appearance/disappearance so `grep PROCESS watchdog.log`
        # shows exactly when each clone died and in what order.
        prev = getattr(t, "_was_running", None)
        if prev is not None and prev != running:
            self.log.log(f"{t.label}: PROCESS {'STARTED' if running else 'DIED'}")
        t._was_running = running

        if not running:
            # Android can briefly report no PID while Roblox is transitioning,
            # so debounce a few ticks before acting. Once confirmed, launching
            # a not-running instance is always the watchdog's job:
            #   - TRADING accounts recover immediately.
            #   - FARMING accounts now also recover immediately (v3.4); before,
            #     a killed clone sat dead until its rejoin timer came due.
            # crash_restart_enabled only controls whether to restart something
            # that IS running but looks unhealthy.
            t.not_running_ticks += 1
            t.last_cpu = None
            t.stale_ticks = 0

            confirmed = t.not_running_ticks >= self.NOT_RUNNING_CONFIRM_TICKS
            should_launch = confirmed

            # Spread out cold starts: several at once overload the phone and
            # make Android's low-memory killer kill the other clones.
            if should_launch and time.time() - self.last_launch_any < self.LAUNCH_STAGGER_SEC:
                should_launch = False

            if should_launch:
                if t.hub_state == "TRADING":
                    reason = "trading session not running"
                elif t.last_rejoin == 0:
                    reason = "initial join"
                elif due:
                    reason = "scheduled rejoin (was not running)"
                else:
                    reason = "process died; relaunching"
                t.status = "launching"
                self.restart(t, reason)
                t.not_running_ticks = 0
            elif confirmed:
                t.status = "not running (waiting for launch slot)"
            else:
                t.status = f"not running ({t.not_running_ticks}x)"
            self.heartbeat(t)
            return

        t.not_running_ticks = 0

        # Process exists - but does it own an Activity? (App Cloner's
        # PersistentAppService can keep a service-only process alive.)
        if self.check_zombie(t):
            if time.time() - self.last_launch_any >= self.LAUNCH_STAGGER_SEC:
                self.log.log(f"{t.label}: process exists but owns no Activity (service-only); treating as dead")
                t.status = "not running (no activity)"
                self.restart(t, "zombie: process alive but no Activity")
                self.heartbeat(t)
                return
        elif getattr(t, "_zombie_ticks", 0) > 0:
            t.status = f"not running (no activity {t._zombie_ticks}x)"
            self.heartbeat(t)
            return

        if self.check_hubcfg_pending(t) or self.check_sea_switch(t):
            self.heartbeat(t)
            return

        if self.crash_restart_enabled:
            state = self.health(t)
            if (state in ("hung", "dialog")
                    and time.time() - self.last_crash_restart >= self.MIN_GAP_BETWEEN_CRASH_RESTARTS):
                self.last_crash_restart = time.time()
                t.status = state
                self.restart(t, state)
                self.heartbeat(t)
                return

        t.status = "trading" if t.hub_state == "TRADING" else "running"
        t.fail_streak = 0

        # Scheduled rejoin applies only to farming. Trading accounts remain in
        # the persistent trading server until Hub changes desired_state back to FARMING.
        if due and t.hub_state != "TRADING":
            self.restart(t, "scheduled rejoin")

        self.heartbeat(t)

    def run(self) -> None:
        self.running = True
        self.log.log(f"Watchdog v{VERSION} started with {len(self.targets)} target(s)")
        if self.hub.enabled:
            self.log.log(f"Hub enabled: {self.hub.base_url}, poll={self.hub_poll_sec}s")
        else:
            self.log.log("Hub disabled (set Hub URL + token in Hub Settings)")

        self.rec_write(
            f"\n######## watchdog v{VERSION} started {now_str()} | android: "
            + self._rec_shell('getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.model')
            .replace("\n", " / ")
            + f" | focus_handoff={'ON' if self.focus_handoff else 'OFF'}"
            + f" | soft_return={'ON' if self.soft_return else 'OFF'}"
        )

        # Pull the real desired state BEFORE writing LocalTrader_Hub.json or
        # touching any Roblox process. This preserves TRADING across a watchdog
        # restart instead of temporarily telling LocalTrader to FARM.
        self.guard("post_mortem", self.post_mortem)
        self.touch_alive()
        self.guard("poll_hub", self.poll_hub)

        # v3.8: shield Termux and this script from the low-memory killer.
        self.guard("protect_termux", self.protect_termux, True)
        if self.proof:
            self.guard("proof.start", self.proof.start)

        # Do not restart clones that are already running; just start their timers.
        self.guard("adopt_running_targets", self.adopt_running_targets)

        for t in self.targets:
            if t.enabled:
                self.guard("autoexec", self.ensure_autoexec, t, True)
                self.guard("sync_config", self.sync_localtrader_config, t)
                self.guard("heartbeat", self.heartbeat, t)

        try:
            last_tick = 0.0
            last_alive = 0.0
            while self.running:
                try:
                    self.poll_hub()
                    self.run_pending_transition()
                    self.protect_termux()
                    self.run_due_snapshots()
                    now = time.time()
                    if now - last_tick >= self.interval_sec:
                        last_tick = now
                        for t in self.targets:
                            try:
                                self.tick(t)
                            except Exception as e:
                                t.status = "error"
                                self.log.log(f"{t.label}: tick exception: {e}")
                                self.log.log(traceback.format_exc()[-2000:])
                    self.draw()
                    if time.time() - last_alive >= 10:
                        last_alive = time.time()
                        self.touch_alive()
                except Exception as e:
                    # v4.0: one bad iteration must never end the watchdog.
                    self.log.log(f"MAIN LOOP error (continuing): {type(e).__name__}: {e}")
                    self.log.log(traceback.format_exc()[-2500:])
                    time.sleep(2)
                time.sleep(1)
        finally:
            self.running = False
            if self.proof:
                self.proof.stop()
            self.clear_alive()
            self.log.log("Watchdog stopped")

    def stop(self) -> None:
        self.running = False

    def render(self) -> str:
        lines = []
        lines.append(f"ROBLOX WATCHDOG v{VERSION} | {now_str()}")
        lines.append("=" * 86)
        hubtxt = self.hub.base_url if self.hub.enabled else "OFF"
        cr = "ON" if self.crash_restart_enabled else "OFF (timer-only rejoin)"
        lines.append(f"Hub: {hubtxt} | poll {self.hub_poll_sec}s | crash-restart: {cr} | autoexec: {'ON' if self.autoexec.enabled else 'OFF'}")
        if self.pending_transitions:
            lines.append(f"Queued transitions: {len(self.pending_transitions)}")
        if self.proof is not None:
            lines.append(f"Proof recorder: {self.proof.status_text()}")
        lines.append("-")
        for i, t in enumerate(self.targets, 1):
            pid = getattr(t, "_pid", "") or "-"
            age = "-"
            if t.last_rejoin:
                age = f"{int((time.time()-t.last_rejoin)/60)}m"
            lines.append(
                f"{i:02d} {t.label[:18]:18} {t.package[:28]:28} "
                f"PID={pid:>7} MODE={t.hub_state:7} STATUS={t.status:20} REJOIN={age:>5}"
            )
            if t.hub_error:
                lines.append(f"    HUB ERROR: {t.hub_error[:180]}")
        lines.append("=" * 86)
        lines.append("Ctrl+C to stop")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Embedded helper files (written out by the menu / CLI, nothing to download)
# ---------------------------------------------------------------------------
SUP_TARGET = "/data/local/tmp/rw_supervisor.sh"
SUP_PIDFILE = "/data/local/tmp/rw_supervisor.pid"
BOOT_HOOK = "/data/adb/service.d/rw_supervisor.sh"

SUPERVISOR_SH = r'''#!/system/bin/sh
# rw_supervisor.sh - keeps rw.py alive even when the Termux app itself is killed.
#
# Runs as root, OUTSIDE the Termux app, so Android's low-memory killer does not
# take it down together with Termux. Every CHECK seconds it looks at
# watchdog.lock (rw.py writes its PID there); if that process is gone it starts
#   python3 rw.py start
# as root (headless). Running rw.py as root also removes the need for `su -c`
# on every command, which makes it much lighter.
#
# Start:  sh install_supervisor.sh          (from Termux, see that file)
# Stop:   su -c 'touch <APPDIR>/supervisor.stop'
# Log:    <APPDIR>/supervisor.log
# View:   python3 rw.py watch               (live screen of the headless watchdog)

APPDIR="${RW_DIR:-/data/data/com.termux/files/home}"
SCRIPT="${RW_SCRIPT:-rw.py}"
PREFIX=/data/data/com.termux/files/usr
LOG="$APPDIR/supervisor.log"
PIDFILE=/data/local/tmp/rw_supervisor.pid
STOPFILE="$APPDIR/supervisor.stop"
CHECK="${RW_CHECK:-15}"
SETTLE="${RW_SETTLE:-25}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "${sz:-0}" -gt 1000000 ] && mv -f "$LOG" "$LOG.1"
}

# --- only one supervisor at a time ----------------------------------------
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$$" ] && [ -d "/proc/$old" ] \
       && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q rw_supervisor; then
        echo "supervisor already running (pid $old)"
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
rm -f "$STOPFILE"
trap 'rm -f "$PIDFILE"; log "supervisor exiting"; exit 0' TERM INT

# --- is rw.py alive? (lock file holds its PID) -----------------------------
wd_alive() {
    pid=$(head -n1 "$APPDIR/watchdog.lock" 2>/dev/null | tr -dc '0-9')
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "$SCRIPT"
}

fix_owner() {
    # rw.py runs as root here; hand its files back so Termux (normal user) can still edit them
    u=$(stat -c %u "$APPDIR" 2>/dev/null)
    [ -n "$u" ] || return 0
    for f in "$APPDIR"/watchdog_config.json "$APPDIR"/watchdog.log* "$APPDIR"/flight_recorder.log* \
             "$APPDIR"/watchdog.lock "$APPDIR"/watchdog.alive "$APPDIR"/watchdog_screen.txt \
             "$APPDIR"/watchdog_fault.log "$APPDIR"/watchdog_stdout.log "$APPDIR"/supervisor.log*; do
        [ -e "$f" ] && chown "$u:$u" "$f" 2>/dev/null
    done
}

start_wd() {
    cd "$APPDIR" || { log "APPDIR $APPDIR missing"; return 1; }
    export HOME=/data/data/com.termux/files/home PREFIX="$PREFIX" TMPDIR="$PREFIX/tmp" \
           LD_LIBRARY_PATH="$PREFIX/lib" LANG=en_US.UTF-8 TERM=dumb PYTHONDONTWRITEBYTECODE=1
    # system tools first (pidof/ps/am/pm), Termux tools last (python3)
    export PATH="/system/bin:/system/xbin:$PATH:$PREFIX/bin"
    nohup python3 "$APPDIR/$SCRIPT" start </dev/null >> "$APPDIR/watchdog_stdout.log" 2>&1 &
    log "started $SCRIPT (pid $!)"
}

# keep Termux out of Doze / battery restrictions (harmless if already set)
cmd deviceidle whitelist +com.termux >/dev/null 2>&1

log "supervisor started (pid $$, appdir $APPDIR, script $SCRIPT)"
fails=0
last_start=0
while :; do
    if [ -f "$STOPFILE" ]; then
        log "stop file found"
        rm -f "$STOPFILE" "$PIDFILE"
        exit 0
    fi
    if wd_alive; then
        fails=0
    else
        now=$(date +%s)
        backoff=$((10 * fails))
        [ "$backoff" -gt 120 ] && backoff=120
        if [ $((now - last_start)) -ge "$backoff" ]; then
            log "watchdog not running -> starting (previous quick failures: $fails)"
            fix_owner
            start_wd
            last_start=$now
            sleep "$SETTLE"
            if wd_alive; then fails=0; else fails=$((fails + 1)); fi
        fi
    fi
    fix_owner
    sleep "$CHECK"
done
'''

LUA_HELPER = r'''-- rwproof.lua : tells the Termux watchdog (rw.py) to record a proof video of a trade.
-- LocalTrader already contains this block (since v2.4); this file is only for other scripts.
--
--   RWProof.start(requestId)                 -- trade is about to complete (accept pressed / countdown)
--   RWProof.done(requestId, result)          -- result: "completed" | "unverified" | "aborted"
--                                            -- ("aborted" recordings are discarded by rw.py)
--
-- Never yields, never throws, so it cannot break trade logic.

-- >>> RWProof BEGIN
local RWProof = {}
do
	local HttpService = game:GetService("HttpService")
	local CFG_FILE = (CONFIG and CONFIG.HubConfigFile) or "LocalTrader_Hub.json" -- written by rw.py
	local SIGNAL_FILE = "LocalTrader_Signal.json"                                -- fallback channel polled by rw.py

	local function readCfg()
		local ok, res = pcall(function()
			return HttpService:JSONDecode(readfile(CFG_FILE))
		end)
		return (ok and type(res) == "table") and res or {}
	end

	local function send(event, requestId, result)
		local cfg = readCfg()
		if cfg.proof_enabled == false then
			return
		end
		local account = tostring(cfg.account_id or "")
		if account == "" then
			return
		end
		local rid = tostring(requestId or cfg.request_id or "")
		local base = tostring(cfg.proof_url or "")
		if base == "" then
			base = "http://127.0.0.1:8799"
		end
		local url = base .. "/proof/" .. event
			.. "?account=" .. HttpService:UrlEncode(account)
			.. "&id=" .. HttpService:UrlEncode(rid)
			.. "&result=" .. HttpService:UrlEncode(tostring(result or ""))

		task.spawn(function()
			-- 1) instant: local HTTP call to the watchdog
			local env = (type(getgenv) == "function" and getgenv()) or _G
			local requestFn = env.request or env.http_request
			if type(requestFn) ~= "function" and type(env.syn) == "table" then
				requestFn = env.syn.request
			end
			local delivered = false
			if type(requestFn) == "function" then
				local ok, response = pcall(requestFn, { Url = url, Method = "GET" })
				delivered = ok and type(response) == "table"
					and (tonumber(response.StatusCode or response.status_code) or 0) == 200
			end
			if not delivered then
				pcall(function()
					game:HttpGet(url)
				end)
			end
			-- 2) fallback: signal file (the watchdog ignores the duplicate)
			pcall(function()
				writefile(SIGNAL_FILE, HttpService:JSONEncode({
					account_id = account,
					event = event,
					request_id = rid,
					result = tostring(result or ""),
					seq = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)),
					ts = os.time(),
				}))
			end)
		end)
	end

	function RWProof.start(requestId)
		send("start", requestId, "")
	end

	function RWProof.done(requestId, result)
		send("done", requestId, result)
	end

	-- Session helpers (a "session" is any table; they keep two fields on it).
	local function requestIdOf(sess)
		local order = sess and sess.externalOrder
		return tostring((order and (order.request_id or order.order_id)) or (sess and sess.orderId) or "")
	end

	-- Safe to call as often as you like: re-sends at most every 2 s, so the watchdog also
	-- starts a fresh recording if an earlier one hit its length cap.
	function RWProof.begin(sess)
		if not sess then
			return
		end
		local now = os.clock()
		if sess.proofActive and now - (sess.proofSentAt or 0) < 2 then
			return
		end
		sess.proofActive = true
		sess.proofSentAt = now
		pcall(RWProof.start, requestIdOf(sess))
	end

	-- Only does something if begin() was called before; ends the recording once.
	function RWProof.finish(sess, result)
		if not sess or not sess.proofActive then
			return
		end
		sess.proofActive = false
		pcall(RWProof.done, requestIdOf(sess), result)
	end
end
-- <<< RWProof END

return RWProof
'''


class App:
    def __init__(self) -> None:
        self.logger = Logger(LOG_PATH)
        self.shell = Shell(self.logger)
        self.detector = Detector(self.shell)
        self.targets: List[Target] = []
        self.interval_sec = 20
        self.hang_sec = 90
        self.crash_restart_enabled = False
        self.focus_handoff = False
        self.soft_return = False
        self.trading_share_link = DEFAULT_TRADING_SHARE_LINK
        self.hub_url = ""
        self.hub_token = ""
        self.hub_poll_sec = DEFAULT_HUB_POLL_SEC
        self.autoexec = dict(DEFAULT_AUTOEXEC)
        self.proof = dict(DEFAULT_PROOF)
        self.hubcfg = dict(DEFAULT_HUBCFG)
        self.device_id = ""
        self.load()

    def load(self) -> None:
        if not os.path.exists(CONFIG_PATH):
            return
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                c = json.load(f)
            global DEVICE_ID
            self.device_id = clean_device_id(c.get("device_id", ""))
            DEVICE_ID = self.device_id                 # before the Targets below are built
            self.interval_sec = int(c.get("check_interval_sec", 20))
            self.hang_sec = int(c.get("hang_detection_sec", 90))
            self.crash_restart_enabled = bool(c.get("crash_restart_enabled", False))
            self.focus_handoff = bool(c.get("focus_handoff", False))
            self.soft_return = bool(c.get("soft_return", False))
            self.trading_share_link = c.get("trading_share_link", DEFAULT_TRADING_SHARE_LINK)
            self.autoexec = {**DEFAULT_AUTOEXEC, **(c.get("autoexec") or {})}
            self.proof = {**DEFAULT_PROOF, **(c.get("proof") or {})}
            self.hubcfg = {**DEFAULT_HUBCFG, **(c.get("hubcfg") or {})}
            hub = c.get("hub", {}) or {}
            self.hub_url = str(hub.get("url", ""))
            self.hub_token = str(hub.get("token", ""))
            self.hub_poll_sec = int(hub.get("poll_sec", DEFAULT_HUB_POLL_SEC))
            self.targets = [Target(**x) for x in c.get("targets", [])]
        except Exception as e:
            self.logger.log(f"config load failed: {e}")

    def save(self) -> None:
        data = {
            "version": VERSION,
            "device_id": self.device_id,
            "check_interval_sec": self.interval_sec,
            "hang_detection_sec": self.hang_sec,
            "crash_restart_enabled": self.crash_restart_enabled,
            "focus_handoff": self.focus_handoff,
            "soft_return": self.soft_return,
            "trading_share_link": self.trading_share_link,
            "autoexec": self.autoexec,
            "proof": self.proof,
            "hubcfg": self.hubcfg,
            "hub": {
                "url": self.hub_url,
                "token": self.hub_token,
                "poll_sec": self.hub_poll_sec,
            },
            "targets": [],
        }
        for t in self.targets:
            d = dataclasses.asdict(t)
            # Runtime values should not be persisted.
            for k in [
                "last_rejoin", "last_launch", "last_heartbeat", "cpu", "stale",
                "fail_streak", "cooldown_until", "restarts", "status", "hub_state",
                "hub_request_id", "hub_version", "hub_error", "trading_join_attempted",
                "not_running_ticks",
            ]:
                d.pop(k, None)
            data["targets"].append(d)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        self.logger.log("configuration saved")

    def ask(self, prompt: str, default: str = "") -> str:
        suffix = f" [{default}]" if default else ""
        try:
            value = input(prompt + suffix + ": ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return default
        return value if value else default

    def yesno(self, prompt: str, default: bool = True) -> bool:
        d = "Y/n" if default else "y/N"
        value = input(f"{prompt} [{d}]: ").strip().lower()
        if not value:
            return default
        return value in ("y", "yes", "1", "true")

    def setup_wizard(self) -> None:
        clear_screen()
        print(f"ROBLOX WATCHDOG v{VERSION} — Auto Setup")
        print("=" * 70)
        print("This setup configures the Android watchdog. Hub settings are optional here.")
        print()
        if not self.shell.has_root_access():
            print("[!] Root was not detected. The watchdog needs root for reliable process/package control.")
        else:
            print("[OK] Root detected (su elevation confirmed)")

        found = self.detector.scan()
        print(f"\nDetected Roblox-like packages: {len(found)}")
        for i, p in enumerate(found, 1):
            print(f"  {i}. {p['package']} (uid {p['uid']})")
        print()

        selected: List[Target] = []
        if found:
            raw = self.ask("Select packages by numbers, comma-separated", "1")
            try:
                indexes = [int(x.strip()) for x in raw.split(",") if x.strip()]
            except ValueError:
                indexes = [1]
            for idx in indexes:
                if 1 <= idx <= len(found):
                    p = found[idx - 1]
                    selected.append(Target(package=p["package"], user_id=p["uid"]))

        if not selected:
            package = self.ask("Roblox package name")
            if package:
                selected = [Target(package=package)]

        place = self.ask("Farming Place ID", self.targets[0].place_id if self.targets else "2753915549")
        farming_link = self.ask(
            "Farming private-server share/legacy link (optional)",
            self.targets[0].private_link if self.targets else ""
        )
        interval = self.ask("Rejoin interval in minutes", str(self.targets[0].rejoin_interval_min if self.targets else 45))
        try:
            interval_i = max(0, int(interval))
        except ValueError:
            interval_i = 45

        for t in selected:
            t.place_id = place
            t.private_link = farming_link
            t.rejoin_interval_min = interval_i

        self.targets = selected
        self.trading_share_link = self.ask("Trading private-server share link", self.trading_share_link)

        if self.yesno("Configure Hub now?", bool(self.hub_url and self.hub_token)):
            self.hub_settings(interactive=True)

        self.save()
        print("\nSetup saved. Press Enter...")
        input()

    def hub_settings(self, interactive: bool = False) -> None:
        clear_screen()
        print("HUB SETTINGS")
        print("=" * 70)
        print("The Hub runs on your PC. The phone connects to the PC's LAN IP.")
        print("Example: http://192.168.1.50:8787")
        print("The token is printed by hub.py when it starts.")
        print()
        self.hub_url = self.ask("Hub URL", self.hub_url)
        self.hub_token = self.ask("Hub token", self.hub_token)
        try:
            self.hub_poll_sec = max(1, int(self.ask("Hub poll interval (seconds)", str(self.hub_poll_sec))))
        except ValueError:
            self.hub_poll_sec = DEFAULT_HUB_POLL_SEC
        self.save()
        if interactive:
            return
        print("\nHub settings saved. Press Enter...")
        input()

    def scan_packages(self) -> None:
        clear_screen()
        print("ROBLOX PACKAGE SCAN")
        print("=" * 70)
        found = self.detector.scan()
        if not found:
            print("No matching packages found.")
        else:
            for i, p in enumerate(found, 1):
                print(f"{i:02d}. {p['package']}  uid={p['uid']}")
                path = self.detector.package_path(p["package"])
                if path:
                    print(f"    {path}")
        input("\nPress Enter...")

    def edit_instances(self) -> None:
        while True:
            clear_screen()
            print("EDIT INSTANCES")
            print("=" * 70)
            if not self.targets:
                print("No instances configured.")
            for i, t in enumerate(self.targets, 1):
                print(f"{i}. {t.label} | {t.package} | place={t.place_id} | enabled={t.enabled}")
            print("\nA = add   D = delete   E = edit   B = back")
            choice = input("> ").strip().lower()
            if choice == "b":
                self.save()
                return
            if choice == "a":
                package = self.ask("Package")
                if package:
                    t = Target(package=package)
                    t.label = self.ask("Label", package)
                    t.place_id = self.ask("Place ID", "2753915549")
                    t.private_link = self.ask("Farming private link", "")
                    try:
                        t.rejoin_interval_min = max(0, int(self.ask("Rejoin minutes", "45")))
                    except ValueError:
                        t.rejoin_interval_min = 45
                    self.targets.append(t)
                    self.save()
            elif choice in ("d", "e"):
                try:
                    idx = int(self.ask("Instance number")) - 1
                except ValueError:
                    continue
                if not (0 <= idx < len(self.targets)):
                    continue
                t = self.targets[idx]
                if choice == "d":
                    self.targets.pop(idx)
                else:
                    t.label = self.ask("Label", t.label)
                    t.place_id = self.ask("Place ID", t.place_id)
                    t.private_link = self.ask("Farming private link", t.private_link)
                    try:
                        t.rejoin_interval_min = max(0, int(self.ask("Rejoin minutes", str(t.rejoin_interval_min))))
                    except ValueError:
                        pass
                    t.enabled = self.yesno("Enabled?", t.enabled)
                self.save()

    def diagnostics(self) -> None:
        clear_screen()
        print("DIAGNOSTICS")
        print("=" * 70)
        su_probe = self.shell.out("su -c id", timeout=15)
        print(f"Root access (su elevation): {self.shell.has_root_access()}")
        print(f"  raw `su -c id` output: {su_probe!r}")
        print(f"Process already uid 0: {self.shell.is_root()}  (normally False under Termux, unrelated to su working)")
        print(f"Config: {CONFIG_PATH}")
        print(f"Log: {LOG_PATH}")
        print(f"Hub: {self.hub_url or 'OFF'}")
        print(f"Crash-restart: {'ON' if self.crash_restart_enabled else 'OFF (timer-only rejoin)'}")
        print(f"Soft return: {'ON' if self.soft_return else 'OFF'}")
        print(f"Trading link: {self.trading_share_link}")
        print()
        controller = Controller(self.shell, self.logger)
        for t in self.targets:
            print(f"{t.label}: package={t.package} hub_id={t.hub_id}")
            pidof_out = self.shell.out("pidof " + shlex.quote(t.package))
            name_match_out = self.shell.out(
                "ps -A 2>/dev/null | awk -v p=" + shlex.quote(t.package) + " '$NF==p{print $2; exit}'"
            )
            resolved_uid = controller.resolve_uid(t.package)
            uid_ps_out = ""
            if resolved_uid is not None:
                uid_ps_out = self.shell.out(
                    f"ps -Ao PID,UID,NAME 2>/dev/null | awk -v u={resolved_uid} '$2==u{{print $1, $3}}'"
                )
            detected_pid = controller.pid(t.package)
            print(f"    pidof {t.package} -> {pidof_out!r}")
            print(f"    ps -A exact name {t.package} -> {name_match_out!r}")
            print(f"    resolved uid -> {resolved_uid!r}")
            print(f"    ps by uid {resolved_uid} -> {uid_ps_out!r}")
            print(f"    => Controller.pid() result: {detected_pid or 'NOT FOUND'}")
        print()
        input("Press Enter...")

    def plain_mode(self) -> None:
        clear_screen()
        print("PLAIN MODE")
        print("=" * 70)
        print("Commands: start | stop <package> | launch <index> | trade <index> | status | back")
        controller = Controller(self.shell, self.logger)
        while True:
            try:
                cmd = input("plain> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return
            if cmd == "back":
                return
            if cmd == "status":
                for i, t in enumerate(self.targets, 1):
                    print(i, t.package, controller.pid(t.package) or "stopped")
            elif cmd.startswith("stop "):
                p = cmd[5:].strip()
                self.shell.root(f"am force-stop {shlex.quote(p)}")
            elif cmd.startswith("launch "):
                try:
                    idx = int(cmd.split()[1]) - 1
                    controller.launch(self.targets[idx])
                except Exception as e:
                    print(e)
            elif cmd.startswith("trade "):
                try:
                    idx = int(cmd.split()[1]) - 1
                    controller.force_stop(self.targets[idx])
                    controller.launch_trading(self.targets[idx], self.trading_share_link)
                except Exception as e:
                    print(e)
            elif cmd == "start":
                self.start_watchdog()
                return
            else:
                print("Unknown command")

    def start_watchdog(self) -> None:
        if not self.targets:
            print("No targets configured. Run Auto Setup first.")
            input("Press Enter...")
            return
        lock_fh, holder = acquire_instance_lock()
        if lock_fh is None:
            print(f"Another watchdog is already running (PID {holder}).")
            print("Stop it first (for example: pkill -f rw.py), then start again.")
            input("Press Enter...")
            return
        wd = Watchdog(
            self.targets,
            self.interval_sec,
            self.hang_sec,
            self.trading_share_link,
            self.hub_url,
            self.hub_token,
            self.hub_poll_sec,
            self.logger,
            self.crash_restart_enabled,
            self.focus_handoff,
            self.soft_return,
            self.autoexec,
            self.proof,
            self.hubcfg,
        )

        def sigint(_sig, _frame):
            wd.stop()

        old = signal.signal(signal.SIGINT, sigint)
        try:
            # v4.0: closing the Termux window sends SIGHUP; survive it (output
            # errors are handled by Watchdog.draw()). SIGTERM is logged.
            signal.signal(signal.SIGHUP, lambda *_: self.logger.log("SIGHUP received (terminal closed) - ignoring"))
            signal.signal(signal.SIGTERM, lambda *_: (self.logger.log("SIGTERM received - stopping"), wd.stop()))
        except Exception:
            pass
        clear_screen()
        try:
            wd.run()
        finally:
            signal.signal(signal.SIGINT, old)
            _resane_tty()
            clear_screen()
            try:
                lock_fh.close()   # releases the single-instance lock
            except Exception:
                pass

    def autoexec_menu(self) -> None:
        inst = AutoexecInstaller(self.shell, self.logger, self.autoexec)
        while True:
            inst.cfg = {**DEFAULT_AUTOEXEC, **self.autoexec}
            clear_screen()
            print("LOCALTRADER AUTOEXEC")
            print("=" * 70)
            print(f"Status : {'ON' if inst.enabled else 'OFF'}")
            print(f"Script : {inst.cfg['script_url']}")
            print(f"File   : {inst.file_name()}  (in each clone's Autoexec folder, found automatically)")
            print(f"Clones : {len([t for t in self.targets if t.enabled])}")
            print()
            print("i = install / check now in every clone")
            print("r = remove the file from every clone")
            print("t = switch on/off     u = change the script URL     b = back")
            choice = input("\n> ").strip().lower()
            if choice == "b":
                return
            if choice == "t":
                self.autoexec["enabled"] = not inst.enabled
                self.save()
            elif choice == "u":
                new = self.ask("Script URL", inst.cfg["script_url"]).strip()
                if new:
                    self.autoexec["script_url"] = new
                    self.save()
                    for t in self.targets:
                        t._autoexec_at = 0.0
                    print("Saved. Choose 'i' to write it into the clones now (a running watchdog picks it up at its next launch check).")
                    input("Press Enter...")
            elif choice in ("i", "r"):
                if choice == "i" and not inst.enabled:
                    print("Autoexec is switched off (press t first).")
                for t in self.targets:
                    if not t.enabled:
                        continue
                    ok, msg = inst.ensure(t, self.targets, force=True) if choice == "i" else inst.remove(t, self.targets)
                    print(f"  {'OK ' if ok else 'FAIL'} {t.label}: {msg}")
                input("\nPress Enter...")

    def set_device_id(self, name: str) -> str:
        """Give this phone a name and re-derive the auto-made Hub ids (rbx-<12 hex>) of every instance from it."""
        global DEVICE_ID
        new = clean_device_id(name)
        if not new:
            return "Use letters, digits, - or _ (max 20), for example:  python3 rw.py device-id phone2"
        old_dev = self.device_id
        lines = []
        for t in self.targets:
            if not re.fullmatch(r"rbx-[0-9a-f]{12}", t.hub_id or ""):
                lines.append(f"  {t.label}: keeps its own custom id {t.hub_id!r}")
                continue
            DEVICE_ID = old_dev
            was = account_id_for_target(Target(package=t.package, user_id=t.user_id))
            DEVICE_ID = new
            now = account_id_for_target(Target(package=t.package, user_id=t.user_id))
            if t.hub_id in (was, now):
                lines.append(f"  {t.label}: {t.hub_id} -> {now}")
                t.hub_id = now
            else:
                lines.append(f"  {t.label}: id {t.hub_id!r} was not made from package+uid, left alone")
        self.device_id = DEVICE_ID = new
        self.save()
        return (f"This phone is now called {new!r}. New Hub ids:\n" + "\n".join(lines) +
                "\n\nThe Hub will list these as NEW accounts (its old, fused entry stays until you delete it on the dashboard).\n"
                "Restart the watchdog (supervisor-stop, wait 20 s, install-supervisor) and relaunch the clones once so the\n"
                "in-game script picks up its new account id.")

    def make_hubcfg(self) -> "HubConfigInstaller":
        hub = HubClient(self.hub_url, self.hub_token, self.logger)

        def sea_fn(t: Target) -> Tuple[int, str]:
            hs = 0
            if hub.enabled:
                try:
                    hs = int(hub.poll(t).get("sea", 0) or 0)
                except Exception:
                    hs = 0
            return resolve_sea(t, hs)
        return HubConfigInstaller(self.shell, self.logger, self.hubcfg,
                                  AutoexecInstaller(self.shell, self.logger, self.autoexec).clone_name_for, sea_fn)

    def hubcfg_menu(self) -> None:
        inst = self.make_hubcfg()
        while True:
            inst.cfg = {**DEFAULT_HUBCFG, **self.hubcfg}
            clear_screen()
            print("QUANTUM ONYX HUB CONFIG")
            print("=" * 70)
            print(f"Status   : {'ON' if inst.enabled else 'OFF'}  (applied before every (re)launch of a clone)")
            print(f"Sea 2 link : {inst.cfg['url_sea2'] or '(none)'}")
            print(f"Sea 1      : {inst.cfg['url_sea1'] or 'Sea 2 file + sea1_overrides (watchdog_config.json -> hubcfg)'}")
            print(f"Fallback   : {inst.template_path()}")
            print(f"Right now  : {inst.template_problem() or 'a usable config is available'}")
            print(f"Target   : <clone>/{inst.cfg['dir_name']}/{inst.cfg['file_glob']}")
            print()
            print("a = apply to every clone NOW (best when the clones are stopped: a running hub can overwrite it again)")
            print("t = switch on/off     b = back")
            choice = input("\n> ").strip().lower()
            if choice == "b":
                return
            if choice == "t":
                self.hubcfg["enabled"] = not inst.enabled
                self.save()
            elif choice == "a":
                if not inst.enabled:
                    print("Switched off (press t first).")
                for t in self.targets:
                    if not t.enabled:
                        continue
                    ok, msg = inst.apply(t, self.targets)
                    print(f"  {'OK  ' if ok else 'FAIL'} {t.label}: {msg}")
                input("\nPress Enter...")

    def proof_menu(self) -> None:
        while True:
            cfg = {**DEFAULT_PROOF, **self.proof}
            clear_screen()
            print("TRADE PROOF RECORDER")
            print("=" * 70)
            print(f"Status          : {'ON' if cfg['enabled'] else 'OFF'}")
            print(f"Videos          : {cfg['dir']}  (deleted after {cfg['keep_days']} days)")
            print(f"HTTP signal     : http://127.0.0.1:{cfg['port']}/proof/start|done")
            print(f"File signal     : <clone>/Arceus X/Workspace/LocalTrader_Signal.json")
            print(f"Raise to front  : {'yes' if cfg['bring_to_front'] else 'no'}")
            print(f"Stop after done : {cfg['tail_sec']}s   max length {cfg['max_sec']}s   keep last {cfg['keep_last_sec']}s (needs ffmpeg)")
            print()
            print("t = on/off   f = raise-to-front on/off   r = test recording (6 s)")
            print("l = list recent videos   b = back")
            choice = input("\n> ").strip().lower()
            if choice == "b":
                return
            if choice == "t":
                self.proof["enabled"] = not cfg["enabled"]
                self.save()
            elif choice == "f":
                self.proof["bring_to_front"] = not cfg["bring_to_front"]
                self.save()
            elif choice == "l":
                print(self.shell.root_out(f"ls -lt {shlex.quote(cfg['dir'])} 2>&1 | head -15") or "(nothing)")
                input("\nPress Enter...")
            elif choice == "r":
                if not self.targets:
                    print("No instances configured.")
                    input("Press Enter...")
                    continue
                for i, t in enumerate(self.targets, 1):
                    print(f"{i}. {t.label}")
                try:
                    t = self.targets[int(self.ask("Which instance", "1")) - 1]
                except (ValueError, IndexError):
                    continue
                print("Recording 6 s: the clone should jump to the front...")
                rec = ProofRecorder(self.shell, self.logger, lambda: self.targets, cfg, resane=_resane_tty)
                rec.start(http=False)
                try:
                    result = rec.test(t, 6)
                finally:
                    rec.stop()
                print(f"\nResult: {result}")
                print("Open that file on the phone and check the clone is fully visible.")
                input("\nPress Enter...")

    # ------------------------------------------------------------------
    # Supervisor (root loop outside Termux that restarts this script)
    # ------------------------------------------------------------------
    def _stage_and_copy(self, text: str, dest: str, mode: str = "755") -> Tuple[bool, str]:
        """Write text to a temp file in our folder, then copy it to dest as root."""
        stage = os.path.join(BASE_DIR, ".rw_stage.tmp")
        try:
            with open(stage, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            r = self.shell.root(f"cp {shlex.quote(stage)} {shlex.quote(dest)} && chmod {mode} {shlex.quote(dest)}", timeout=20)
            if r.returncode != 0:
                return False, (r.stderr or r.stdout or f"rc={r.returncode}").strip()[:200]
            return True, ""
        except Exception as e:
            return False, f"{type(e).__name__}: {e}"
        finally:
            try:
                os.remove(stage)
            except OSError:
                pass

    def supervisor_status(self) -> str:
        log = shlex.quote(os.path.join(BASE_DIR, "supervisor.log"))
        return self.shell.root_out(
            f'pid=$(cat {SUP_PIDFILE} 2>/dev/null); '
            f'if [ -n "$pid" ] && [ -d /proc/$pid ]; then echo "supervisor RUNNING (pid $pid)"; '
            f'else echo "supervisor NOT running"; fi; '
            f'[ -f /data/adb/service.d/rw_supervisor.sh ] && echo "boot hook: installed" || echo "boot hook: not installed"; '
            f'echo "-- supervisor.log (last lines)"; tail -n 8 {log} 2>/dev/null', timeout=15) or "(no answer from su)"

    def supervisor_install(self) -> str:
        if not self.shell.has_root_access():
            return "Root (su) is not available - cannot install the supervisor."
        ok, err = self._stage_and_copy(SUPERVISOR_SH, SUP_TARGET)
        if not ok:
            return "Could not copy the supervisor to /data/local/tmp: " + err
        name = os.path.basename(os.path.abspath(__file__))
        env = f"RW_DIR={shlex.quote(BASE_DIR)} RW_SCRIPT={shlex.quote(name)}"
        notes = []
        if self.shell.root_out("[ -d /data/adb/service.d ] && echo yes", timeout=10) == "yes":
            hook = "#!/system/bin/sh\nsleep 60\n" + f"{env} sh {SUP_TARGET} &\n"
            ok, err = self._stage_and_copy(hook, BOOT_HOOK)
            notes.append("Boot hook installed (starts after a reboot)." if ok else "Boot hook failed: " + err)
        else:
            notes.append("No /data/adb/service.d here: it will not start by itself after a reboot "
                         "(run this install again after rebooting).")
        notes.append(self.start_supervisor_process())
        time.sleep(2.5)
        return "\n".join(notes) + "\n" + self.supervisor_status()

    def start_supervisor_process(self) -> str:
        """Start rw_supervisor.sh as a long-lived `su` child of this process.

        A `su -c "... &"` that returns is killed on this phone, so `su` itself must stay alive.
        The child gets its own session (survives closing the Termux window) and writes to supervisor_launch.log.
        """
        name = os.path.basename(os.path.abspath(__file__))
        inner = f"RW_DIR={shlex.quote(BASE_DIR)} RW_SCRIPT={shlex.quote(name)} sh {SUP_TARGET}"
        cmd = inner if self.shell.is_root() else "su -c " + shlex.quote(inner)
        logp = os.path.join(BASE_DIR, "supervisor_launch.log")
        try:
            with open(logp, "ab") as out:
                subprocess.Popen(cmd, shell=True, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                                 start_new_session=True)
            return f"Supervisor launch sent (errors, if any, go to {logp})."
        except Exception as e:
            return f"Could not start the supervisor: {type(e).__name__}: {e}"
        finally:
            _resane_tty()

    def install_boot_script(self) -> str:
        """Write ~/.termux/boot/rw.sh for the Termux:Boot app."""
        home = os.path.expanduser("~")
        d = os.path.join(home, ".termux", "boot")
        path = os.path.join(d, "rw.sh")
        name = os.path.basename(os.path.abspath(__file__))
        text = (
            "#!/data/data/com.termux/files/usr/bin/sh\n"
            "# written by rw.py install-boot: starts the supervisor (which starts the watchdog) after a phone restart\n"
            "termux-wake-lock\n"
            "sleep 45\n"
            f"cd {shlex.quote(BASE_DIR)} || exit 1\n"
            f"{shlex.quote(sys.executable)} {shlex.quote(name)} install-supervisor >> boot.log 2>&1\n"
        )
        try:
            os.makedirs(d, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            os.chmod(path, 0o755)
        except Exception as e:
            return f"Could not write {path}: {type(e).__name__}: {e}"
        return (f"Written: {path}\n"
                "Install the Termux:Boot app (same source as Termux) and OPEN IT ONCE, otherwise Android never runs this file.\n"
                "Also: Termux battery = Unrestricted, and root for Termux set to always allow.")

    def supervisor_stop(self) -> str:
        self.shell.root(f"touch {shlex.quote(os.path.join(BASE_DIR, 'supervisor.stop'))}", timeout=10)
        return ("Stop requested - the SUPERVISOR exits within ~15 s. rw.py itself keeps running (that is normal).\n"
                "To stop everything use:  python3 rw.py stop")

    STOP_ALL_SCRIPT = r'''
APPDIR=@@APPDIR@@; SCRIPT=@@SCRIPT@@; PIDFILE=@@PIDFILE@@
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
touch "$APPDIR/supervisor.stop"
i=0
while [ $i -lt 20 ]; do
  sp=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$sp" ] && alive "$sp"; then sleep 1; i=$((i+1)); else break; fi
done
sp=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$sp" ] && alive "$sp"; then kill "$sp" 2>/dev/null; echo "supervisor: did not react to the stop file, killed (pid $sp)"; else echo "supervisor: stopped"; fi
rm -f "$APPDIR/supervisor.stop"
wd=$(head -n1 "$APPDIR/watchdog.lock" 2>/dev/null | tr -dc 0-9)
if [ -n "$wd" ] && [ -r "/proc/$wd/cmdline" ] && tr '\0' ' ' < "/proc/$wd/cmdline" | grep -q "$SCRIPT"; then
  kill "$wd" 2>/dev/null
  j=0
  while [ $j -lt 15 ] && alive "$wd"; do sleep 1; j=$((j+1)); done
  if alive "$wd"; then kill -9 "$wd" 2>/dev/null; sleep 1; echo "watchdog: still alive after 15 s, killed with -9 (pid $wd)"; else echo "watchdog: stopped (pid $wd)"; fi
else
  echo "watchdog: not running"
fi
'''

    def stop_all(self) -> str:
        """Stop the supervisor FIRST (otherwise it restarts the watchdog), then the watchdog. Needs root."""
        if not self.shell.has_root_access():
            return "Root (su) is not available - nothing was stopped."
        name = os.path.basename(os.path.abspath(__file__))
        script = (self.STOP_ALL_SCRIPT.replace("@@APPDIR@@", shlex.quote(BASE_DIR))
                                      .replace("@@SCRIPT@@", shlex.quote(name))
                                      .replace("@@PIDFILE@@", shlex.quote(SUP_PIDFILE)))
        out = self.shell.root_out(script, timeout=60)
        return (out or "(no answer from su)") + "\n\nStart it again with:  python3 rw.py install-supervisor"

    def write_lua_helper(self) -> str:
        path = os.path.join(BASE_DIR, "rwproof.lua")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(LUA_HELPER)
        return path

    def supervisor_menu(self) -> None:
        while True:
            clear_screen()
            print("AUTO-RESTART SUPERVISOR + LUA HELPER")
            print("=" * 70)
            print("The supervisor is a root loop OUTSIDE the Termux app. If this watchdog dies")
            print("(even when Android kills Termux) it starts it again as a headless root process.")
            print("View a headless instance with:  python3 rw.py watch")
            print()
            print(self.supervisor_status())
            print()
            print("i = install / start now   x = STOP EVERYTHING (supervisor + watchdog)   t = write Termux:Boot script   l = write rwproof.lua   b = back")
            choice = input("\n> ").strip().lower()
            if choice == "b":
                return
            if choice == "i":
                print("\n" + self.supervisor_install())
                input("\nPress Enter...")
            elif choice == "x":
                print("\n" + self.stop_all())
                input("\nPress Enter...")
            elif choice == "t":
                print("\n" + self.install_boot_script())
                input("\nPress Enter...")
            elif choice == "l":
                print("\nWritten: " + self.write_lua_helper())
                print("Paste its contents into LocalTrader (or `cat rwproof.lua` to copy it).")
                input("\nPress Enter...")

    def menu(self) -> None:
        while True:
            clear_screen()
            print(f"ROBLOX WATCHDOG v{VERSION}")
            print("=" * 70)
            print(f"Instances: {len(self.targets)}")
            print(f"Hub: {self.hub_url or 'OFF'}")
            print(f"Trading PS: {parse_private_link(self.trading_share_link) or 'INVALID'}")
            print(f"Crash-restart: {'ON' if self.crash_restart_enabled else 'OFF (timer-only rejoin)'}")
            print(f"Focus handoff: {'ON (experimental)' if self.focus_handoff else 'OFF'}")
            print(f"Soft return: {'ON (no force-stop on return to farming)' if self.soft_return else 'OFF'}")
            print()
            print("1. Auto setup")
            print("2. Start watchdog")
            print("3. Scan packages")
            print("4. Edit instances")
            print("5. Hub settings")
            print("6. Diagnostics")
            print("7. Plain mode")
            print("8. Toggle crash-restart")
            print("9. Toggle focus handoff (KNOWN BAD: hides every clone - leave OFF)")
            print("10. Toggle soft return (no force-stop when returning to farming)")
            print("11. LocalTrader autoexec (install / check / remove / on-off / URL)")
            print("12. Trade proof recorder (video of each trade)")
            print("13. Auto-restart supervisor / Lua helper")
            print("14. Quantum Onyx Hub config (one template for every clone)")
            print(f"15. Phone name for the Hub ({self.device_id or 'not set'}) - needed when two phones fuse into one")
            print("0. Exit")
            choice = input("\n> ").strip()
            if choice == "1":
                self.setup_wizard()
            elif choice == "2":
                self.start_watchdog()
            elif choice == "3":
                self.scan_packages()
            elif choice == "4":
                self.edit_instances()
            elif choice == "5":
                self.hub_settings()
            elif choice == "6":
                self.diagnostics()
            elif choice == "7":
                self.plain_mode()
            elif choice == "8":
                self.crash_restart_enabled = not self.crash_restart_enabled
                self.save()
                state = "ON" if self.crash_restart_enabled else "OFF (timer-only rejoin)"
                print(f"\nCrash-restart is now {state}.")
                if self.crash_restart_enabled:
                    print(f"(no checks for {Watchdog.GRACE_AFTER_LAUNCH_SEC}s after a launch; a clone must")
                    print(f" look bad {Watchdog.CONFIRM_BAD_TICKS} checks in a row, and only one clone is")
                    print(f" crash-restarted every {Watchdog.MIN_GAP_BETWEEN_CRASH_RESTARTS}s.)")
                input("Press Enter...")
            elif choice == "9":
                self.focus_handoff = not self.focus_handoff
                self.save()
                print(f"\nFocus handoff is now {'ON' if self.focus_handoff else 'OFF'}.")
                if self.focus_handoff:
                    print("WARNING: tested - bringing Termux to the front hides every Roblox clone")
                    print("(they go to the background like switching apps). Turn this back OFF.")
                input("Press Enter...")
            elif choice == "10":
                self.soft_return = not self.soft_return
                self.save()
                print(f"\nSoft return is now {'ON' if self.soft_return else 'OFF'}.")
                if self.soft_return:
                    print("On RETURN TO FARMING a running clone is not force-stopped; the")
                    print("farming link is sent into it instead. If clones stay in the trading")
                    print("server after a trade, turn this back OFF.")
                input("Press Enter...")
            elif choice == "11":
                self.autoexec_menu()
            elif choice == "12":
                self.proof_menu()
            elif choice == "13":
                self.supervisor_menu()
            elif choice == "14":
                self.hubcfg_menu()
            elif choice == "15":
                name = self.ask("Phone name (letters/digits, e.g. phone2)", self.device_id)
                print("\n" + self.set_device_id(name))
                input("\nPress Enter...")
            elif choice == "0":
                return


def headless_start() -> int:
    # `start` is the normal long-running mode and must have the same tty
    # protection as the interactive menu.
    app = App()
    if not app.targets:
        print("No targets configured. Run: python3 rw.py")
        return 1
    try:
        app.start_watchdog()
        return 0
    finally:
        _resane_tty()


_fault_fh = None


def install_crash_logging() -> None:
    """Make sure that *how* the process died ends up in watchdog.log."""
    global _fault_fh
    def hook(et, ev, tb):
        try:
            Logger(LOG_PATH).log("UNCAUGHT EXCEPTION:\n" + "".join(traceback.format_exception(et, ev, tb))[-2500:])
        except Exception:
            pass
        sys.__excepthook__(et, ev, tb)
    sys.excepthook = hook
    try:
        _fault_fh = open(FAULT_PATH, "a")
        faulthandler.enable(file=_fault_fh)      # native crashes (SIGSEGV/SIGABRT...) get a traceback
    except Exception:
        pass


def watch_screen() -> int:
    """Live view of a headless watchdog: python3 rw.py watch"""
    try:
        while True:
            try:
                with open(SCREEN_PATH, encoding="utf-8") as f:
                    txt = f.read()
            except OSError:
                txt = "(watchdog_screen.txt not found - is the watchdog running?)"
            os.system("clear")
            print(txt)
            time.sleep(1)
    except KeyboardInterrupt:
        return 0


def main() -> int:
    install_crash_logging()
    cmd = sys.argv[1].lower() if len(sys.argv) > 1 else ""
    if cmd == "watch":
        return watch_screen()
    if cmd == "device-id":
        app = App()
        if len(sys.argv) > 2:
            print(app.set_device_id(sys.argv[2]))
        else:
            print(f"device id: {app.device_id or '(not set)'}")
            for t in app.targets:
                print(f"  {t.label}: {t.hub_id}")
            print("Set one with:  python3 rw.py device-id <name>   (use it on every phone except your oldest one)")
        return 0
    if cmd == "hubcfg":
        app = App()
        inst = app.make_hubcfg()
        bad = inst.template_problem()
        if bad:
            print(bad)
            return 1
        for t in app.targets:
            if t.enabled:
                ok, msg = inst.apply(t, app.targets)
                print(f"{'OK  ' if ok else 'FAIL'} {t.label} (Hub id {t.hub_id}): {msg}")
        return 0
    if cmd == "probe":
        app = App()
        script = ('for f in "/storage/emulated/0"/RobloxClone*/"Arceus X"/Workspace/LocalTrader_ItemProbe.txt; do '
                  '[ -f "$f" ] && { echo "=== $f"; cat "$f"; echo; }; done')
        text = app.shell.root_out(script, timeout=30)
        if not text.strip():
            print("No LocalTrader_ItemProbe.txt found. It is written by LocalTrader v2.6 after the first inventory report")
            print("(the account must be in game with a team chosen). Run LocalTrader v2.6 and try again in a minute.")
            return 1
        out = os.path.join(BASE_DIR, "item_probe_all.txt")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(text)
        print(f"\nSaved to {out}")
        return 0
    if cmd in ("install-supervisor", "supervisor-status", "supervisor-stop", "stop", "install-boot", "lua"):
        app = App()
        if cmd == "install-supervisor":
            print(app.supervisor_install())
        elif cmd == "supervisor-status":
            print(app.supervisor_status())
        elif cmd == "supervisor-stop":
            print(app.supervisor_stop())
        elif cmd == "stop":
            print(app.stop_all())
        elif cmd == "install-boot":
            print(app.install_boot_script())
        else:
            path = app.write_lua_helper()
            print(f"Written: {path}\n")
            print(LUA_HELPER)
        return 0
    if len(sys.argv) > 1 and sys.argv[1].lower() == "start":
        return headless_start()
    with Terminal():
        App().menu()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
