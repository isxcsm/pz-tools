#!/usr/bin/env python3
"""Drives a running game (started with -debug) through the command channel of the developer sub-mod OperationAcornDev
(OperationAcornDev/42/media/lua/client/OperationAcorn/Dev/Remote.lua): no typing into the Lua console. Single player;
the helpers in Dev/Dev.lua (OperationAcorn.Dev, also driven by the dev panel) change the save.

Usage:
    python tools/pzdev.py run "OperationAcorn.Dev.state()"     runs Lua in the game, prints what it printed
    python tools/pzdev.py file path/to/script.lua             runs a Lua file the same way
    python tools/pzdev.py check p3_window.lua                 RUN()s an in-game check of tests/ingame, prints its lines
    python tools/pzdev.py shot out.png [--wait 2] [--full]    a picture of the game window (its inside only, or the
                                                              whole screen with --full) after waiting, the game brought
                                                              to the front; --count 6 --every 0.4: a series (out_1.png..)
    python tools/pzdev.py reload                              leaves the save to the main menu and continues it (Lua and
                                                              translations are read again; textures need a restart)
    python tools/pzdev.py menu                                leaves the save for the main menu, returns once there (to
                                                              change the save's files, then continue)
    python tools/pzdev.py continue                            from the main menu (after a game start), continues the
                                                              latest save and waits for it
    python tools/pzdev.py resume                            presses Resume in the game's Lua debugger (with Break On
                                                              Error, any Lua error, even one a pcall catches, stops the
                                                              game there, and the channel with it)
    python tools/pzdev.py launch                              starts the game (if not running: its exe with -debug,
                                                              options.ini set to a 1600x900 window first), waits for
                                                              the main menu, continues the latest save and returns
                                                              once in it; a game without -debug is said at once, one
                                                              full screen on the main menu started again windowed
    python tools/pzdev.py quit                                quits the game to the desktop (to change its files)
    python tools/pzdev.py restart                             quits the game to the desktop (its window closed when
                                                              the channel is silent), then launch
    python tools/pzdev.py wait menu|loading|game|exit|error   returns when the game gets there (--timeout, default 300)
    python tools/pzdev.py watch                               prints one line per event, forever (for a background
                                                              monitor): start, menu, ready, loading, game, error <text>,
                                                              exit, paused, running, unfocused, focused
launch, restart and continue load the save --save names (a Sandbox save's folder), or PZDEV_SAVE's, and refuse with
neither: Continue would load the user's own latest save. latestSave.ini points at it while the main menu is built, so
Continue loads it, and is put back once it loaded: the user's Continue stays theirs. reload loads the save it leaves
(or --save's). The game pzdev
starts is watched by a process of its own (pzdev guard): as it ends, however it ends, the user's display options and
latest save are put back (the game writes its options as it quits from the main menu).
Events come from console.txt (the game's own "STATE: exit ..." lines, a Lua "Exception thrown") and whether the game
window is there: nothing runs in the game, so a normal game is untouched.
Options of run/file/check: --timeout seconds (default 15); --follow seconds: then also print the Lua lines the game
logs for that long (what a check prints a few ticks later; check follows 3 s by default).
Exit status 1 when the command failed in the game or no answer came (the game not running, not in -debug, or
still loading).
"""
import ctypes
import os
import subprocess
import sys
import time

ZOMBOID = os.path.join(os.path.expanduser("~"), "Zomboid", "Lua", "oadev")
CONSOLE = os.path.join(os.path.expanduser("~"), "Zomboid", "console.txt")
OPTIONS = os.path.join(os.path.expanduser("~"), "Zomboid", "options.ini")
# The game's folder (PZDEV_GAME gives another): pzdev starts its exe itself, with -debug.
GAME_DIR = os.environ.get("PZDEV_GAME", r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid")
# The game as pzdev drives it: windowed at this size (the places it clicks are for it; a borderless or full screen game
# is captured black or stale, and its menu is elsewhere).
WINDOW = (1600, 900)
# The user's display options while pzdev's start has them changed.
DISPLAY_KEPT = os.path.join(os.path.expanduser("~"), "Zomboid", "pzdev-display.ini")
CMD = os.path.join(ZOMBOID, "cmd.lua")
OUT = os.path.join(ZOMBOID, "out.txt")


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        value = sys.argv[i + 1]
        del sys.argv[i:i + 2]
        return value
    return default


def console_size():
    try:
        return os.path.getsize(CONSOLE)
    except OSError:
        return 0


# Where the text was last logged since the game started (a byte offset of console.txt), -1 when it was not.
def console_last(text):
    try:
        with open(CONSOLE, "rb") as f:
            return f.read().rfind(text.encode("utf-8"))
    except OSError:
        return -1


def console_has(start, text):
    try:
        with open(CONSOLE, "rb") as f:
            f.seek(start)
            return text.encode("utf-8") in f.read()
    except OSError:
        return False


def game_window():
    return bool(ctypes.windll.user32.FindWindowW(None, "Project Zomboid"))


# Whether the game's window is the one in front (keys and clicks go to it; with the game's pause-on-focus-loss option
# on, the game stops when it is not).
def game_focused():
    window = ctypes.windll.user32.FindWindowW(None, "Project Zomboid")
    return bool(window) and ctypes.windll.user32.GetForegroundWindow() == window


# The game's own state lines and what they mean here: the boot's last screen (terms of service) or a save left gives the
# main menu; the menu left, a load; the load done, the save (the channel answers a moment later).
STATES = {
    "STATE: exit zombie.gameStates.TermsOfServiceState": "menu",
    "STATE: exit zombie.gameStates.IngameState": "menu",
    "STATE: exit zombie.gameStates.MainScreenState": "loading",
    "STATE: exit zombie.gameStates.GameLoadingState": "game",
    # the main menu's background film starting: the menu is built and takes a click (Continue pressed before that is
    # lost, and the Lua of every mod is read again after a save is left, which takes a while)
    "binkId: ": "ready",
    # the dev channel's lines (Dev/Remote.lua): the game paused (the pause key, a menu, or the window's focus lost with
    # the game's option on) or going again
    "[pzdev] paused": "paused",
    "[pzdev] running": "running",
}


# The game's events from now on, one (name, detail) at a time; every `tick` seconds without one, (None, None). The log is
# written again from the start when the game starts, and the window comes and goes with the game; whether the window is
# in front is told as it changes (unfocused, focused).
def events(tick=0.5, start=None):
    offset = console_size() if start is None else start
    running = game_window()
    focused = game_focused()
    partial = b""
    while True:
        out = []
        now_running = game_window()
        if now_running != running:
            running = now_running
            out.append(("start", "") if running else ("exit", ""))
        now_focused = game_focused()
        if running and now_focused != focused:
            out.append(("focused", "") if now_focused else ("unfocused", ""))
        focused = now_focused
        size = console_size()
        if size < offset:
            offset, partial = 0, b""
        if size > offset:
            try:
                with open(CONSOLE, "rb") as f:
                    f.seek(offset)
                    data = partial + f.read(size - offset)
                offset = size
            except OSError:
                data = partial
            lines = data.split(b"\n")
            partial = lines.pop()
            error = None
            for raw in lines:
                line = raw.decode("utf-8", errors="replace").rstrip("\r")
                if error is not None:
                    # the line after "Exception thrown" says what was thrown
                    out.append(("error", error + " | " + line.strip()))
                    error = None
                    continue
                for mark, state in STATES.items():
                    if mark in line:
                        out.append((state, ""))
                if "Exception thrown" in line:
                    error = line.split("> ", 1)[-1].strip()
            if error is not None:
                out.append(("error", error))
        if not out:
            out.append((None, None))
        for item in out:
            yield item
        if out[-1][0] is None:
            time.sleep(tick)


# Waits for one of `names`; returns (name, detail), or (None, None) after `timeout` seconds.
def wait_for(names, timeout, start=None):
    end = time.time() + timeout
    for name, detail in events(start=start):
        if name in names:
            return name, detail
        if time.time() > end:
            return None, None


def watch():
    for name, detail in events():
        if name is not None:
            print((name + " " + detail).strip(), flush=True)


# The Lua print lines the game logged after `start` (a byte offset of console.txt), without the log prefix.
def follow(start, seconds):
    time.sleep(seconds)
    try:
        with open(CONSOLE, "rb") as f:
            f.seek(start)
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return
    for line in text.splitlines():
        if line.startswith("LOG  : Lua"):
            print(line.split("> ", 1)[-1])


def send(code, timeout, quiet=False):
    start = console_size()
    os.makedirs(ZOMBOID, exist_ok=True)
    cid = str(time.time_ns())
    with open(CMD, "w", encoding="utf-8", newline="\n") as f:
        f.write("--#" + cid + "\n" + code + "\n")
    end = time.time() + timeout
    thrown, quiet_since, size = False, None, -1
    while time.time() < end:
        time.sleep(0.1)
        # a Lua error after the command, then no answer and a silent log (the game stopped in the debugger logs nothing)
        # for 1.5 s: no need to wait the timeout out
        thrown = thrown or console_has(start, "Exception thrown")
        if thrown:
            now_size = console_size()
            if now_size != size:
                size, quiet_since = now_size, time.time()
            elif time.time() - quiet_since > 1.5:
                break
        try:
            with open(OUT, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        lines = text.split("\n")
        body = [l for l in lines[1:] if l != ""]
        # done when the last line says how it ended (the game may still be writing the file)
        if lines[0] == "#" + cid and lines[-1] == "" and body and (body[-1] == "ok" or body[-1].startswith("error: ")):
            if not quiet:
                print("\n".join(body))
            return 0 if body[-1] == "ok" else 1
    if quiet:
        return 1
    # stopped in the Lua debugger on an error (Break On Error)? Then the console has the error: show it, resume
    errors = []
    try:
        with open(CONSOLE, "rb") as f:
            f.seek(start)
            for line in f.read().decode("utf-8", errors="replace").splitlines():
                if line.startswith("ERROR") or "attempted" in line or "Exception" in line:
                    errors.append(line.strip())
    except OSError:
        pass
    if errors:
        print("the game stopped on a Lua error:")
        print("\n".join(errors[:6]))
        resume()
    else:
        print("no answer in %ss: is the game running with -debug and in a save?" % timeout)
    return 1


def window_rect(full):
    user32 = ctypes.windll.user32
    user32.SetProcessDPIAware()
    if full:
        return (0, 0, user32.GetSystemMetrics(0), user32.GetSystemMetrics(1))
    hwnd = user32.FindWindowW(None, "Project Zomboid")
    if not hwnd:
        raise SystemExit("no game window")

    class RECT(ctypes.Structure):
        _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    r = RECT()
    user32.GetClientRect(hwnd, ctypes.byref(r))
    p = POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(p))
    return (p.x, p.y, p.x + r.right, p.y + r.bottom)


# Places from the top left of the game window's inside (the windowed 1600x900 game at the 26 pixel font, the main menu
# with PZ Optimization's entries): Resume in the Lua debugger's tool bar, Continue on the main menu (the middle of its
# row). Another window size or font option moves them: PZDEV_RESUME and PZDEV_CONTINUE ("x,y") give them (1280x720 at
# the 16 pixel font: 84,56 for Continue).
def place(name, default):
    value = os.environ.get(name)
    if not value:
        return default
    x, y = value.split(",")
    return (int(x), int(y))


RESUME_AT = place("PZDEV_RESUME", (564, 21))
CONTINUE_AT = place("PZDEV_CONTINUE", (84, 228))


def click(at):
    user32 = ctypes.windll.user32
    left, top, _, _ = window_rect(False)
    hwnd = user32.FindWindowW(None, "Project Zomboid")
    # a window that was not in front: the game draws a few frames a second until it is, and misses a click in one.
    # Windows lets a background process bring a window forward only after a key press: an Alt tap first (else the
    # first click only activates the window, and Continue waited 12 s for its second press at every start).
    settle = 0.3 if user32.GetForegroundWindow() == hwnd else 1.5
    if user32.GetForegroundWindow() != hwnd:
        user32.keybd_event(0x12, 0, 0, 0)
        user32.keybd_event(0x12, 0, 0x0002, 0)
    user32.SetForegroundWindow(hwnd)
    time.sleep(settle)
    # the cursor there for some frames first (and moved once more): a button pressed in the frame the cursor jumps in is
    # read at the old place, and Continue missed its first press at every start
    user32.SetCursorPos(left + at[0] - 2, top + at[1])
    time.sleep(0.4)
    user32.SetCursorPos(left + at[0], top + at[1])
    time.sleep(0.3)
    # down and up several frames apart: the game reads the mouse once a frame and misses a click within one
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.25)
    user32.mouse_event(0x0004, 0, 0, 0, 0)


def resume():
    click(RESUME_AT)
    print("pressed resume")
    return 0


# Leaves the save to the main menu (the game saves it) and continues it: Lua and translations are read again (not
# textures). Returns when the channel answers in the loaded save. A paused game takes the command and never leaves (the
# exit waits for a game frame), so the game is set going first.
def reload():
    start = console_size()
    name = SAVE or current_save()
    if not name:
        print("the save in play is not known (no answer): not left")
        return 1
    point_latest(name)
    if leave_save(start) != 0:
        return 1
    return continue_when_ready(start)


# The folder name of the save in play (through the channel), or None.
def current_save():
    start = console_size()
    if send('print("pzdev-save=" .. tostring(getWorld():getWorld()))', 5, quiet=True) != 0:
        return None
    try:
        with open(CONSOLE, "rb") as f:
            f.seek(start)
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        if "pzdev-save=" in line:
            return line.split("pzdev-save=", 1)[1].strip().rstrip(".")
    return None


# Leaves the save for the main menu and returns once there (its events read from `start`, a byte offset of console.txt
# taken before: a menu reached before the wait began still counts).
def leave_save(start):
    if send("if isGamePaused() then setGameSpeed(1) end getCore():exitToMenu()", 15) != 0:
        return 1
    name, _ = wait_for({"menu"}, 120, start)
    if name != "menu":
        print("the save was not left in 2 minutes")
        return 1
    print("menu")
    return 0


# Waits for the main menu to take clicks (its film starting, after `start`: a byte offset of console.txt), then
# continues the latest save. Without the sign in two minutes it presses Continue anyway (again while it is not taken).
def continue_when_ready(start):
    name, _ = wait_for({"ready", "exit"}, 120, start)
    if name == "exit":
        print("the game closed")
        return 1
    time.sleep(1.5)
    return continue_save()


# Whether a load started after `start` (a byte offset of console.txt): the game's own state line of the main menu left.
# (Mod and map lines are no sign: the menu logs them too as it is built again after a save is left.)
def load_started(start):
    return console_has(start, "STATE: exit zombie.gameStates.MainScreenState")


LATEST = os.path.join(os.path.expanduser("~"), "Zomboid", "latestSave.ini")
# The user's latestSave.ini while --save points it elsewhere.
LATEST_KEPT = os.path.join(os.path.expanduser("~"), "Zomboid", "pzdev-latest.ini")
# The save launch, restart and continue load (--save, or PZDEV_SAVE); none: they refuse.
SAVE = None
NO_SAVE = "name the test save to load: --save <folder under Saves/Sandbox> (or PZDEV_SAVE); Continue alone loads the user's own"


# Points latestSave.ini at a Sandbox save (before the main menu is built: it reads the file then); the user's own is kept
# (unless an earlier run's is kept still) for put_latest_back.
def point_latest(name):
    try:
        with open(LATEST, "rb") as f:
            mine = f.read()
    except OSError:
        mine = None
    if not os.path.exists(LATEST_KEPT):
        with open(LATEST_KEPT, "wb") as f:
            f.write(mine or b"")
    with open(LATEST, "wb") as f:
        f.write((name + "\r\nSandbox").encode("utf-8"))
    print("Continue points at " + name + " for this load")


# The user's latestSave.ini back (the game wrote the loaded save there).
def put_latest_back():
    try:
        with open(LATEST_KEPT, "rb") as f:
            mine = f.read()
    except OSError:
        return
    if mine:
        with open(LATEST, "wb") as f:
            f.write(mine)
    elif os.path.exists(LATEST):
        os.remove(LATEST)
    os.remove(LATEST_KEPT)
    print("Continue points at the user's latest save again")


# Presses Continue on the main menu (again while no load starts: the menu takes no click while it settles, e.g. for the
# 20 seconds or so pzopt preloads the animation sets, and one right after the window comes to the front can be missed)
# and returns when the channel answers in the loaded save.
def continue_save():
    if not os.path.exists(LATEST_KEPT):
        print("Continue points at the user's own latest save (pzdev did not point it before this menu was built): not"
              " pressed. `pzdev restart --save <test save>`")
        return 1
    if full_screen():
        print("the game is full screen: Continue is not where pzdev clicks (`pzdev restart` starts it windowed)")
        return 1
    # The menu takes no click for some seconds after it is built (about 15 s after a save is left): pressed every 3 s
    # until a load starts (a press after that lands on the loading screen, which takes none).
    before = console_size()
    first = time.time()
    for attempt in range(30):
        click(CONTINUE_AT)
        waited = time.time() + 3
        while time.time() < waited and not load_started(before):
            time.sleep(0.25)
        if load_started(before):
            break
    else:
        print("the game did not take Continue in 90 s (is it on the main menu?)")
        return 1
    print("Continue taken after %.0f s" % (time.time() - first))
    status = until_loaded(240)
    put_latest_back()
    return status


# Returns when the channel answers in the loaded save: the load's end comes in the log (the channel asked then; and
# every 10 s anyway, in case the line was missed). A Lua error while loading (vanilla's too) stops the load in the
# debugger: reported and resumed. Every 10 s it says it is still waiting, and what came last; back on the main menu
# (the load failed) it stops at once.
def until_loaded(timeout):
    started = time.time()
    end = started + timeout
    ask_at = started + 10
    last = "loading"
    for name, detail in events():
        if name is not None and name not in ("focused", "unfocused"):
            last = name
        if name == "error":
            print("a Lua error stopped the load:", detail, flush=True)
            click(RESUME_AT)
        elif name == "exit":
            print("the game closed while loading")
            return 1
        elif name == "menu":
            print("back on the main menu: the load failed")
            return 1
        elif name == "game" or time.time() > ask_at:
            for _ in range(10 if name == "game" else 1):
                if send('print("loaded")', 3, quiet=True) == 0:
                    print("loaded")
                    return 0
            print("still loading after %d s (last: %s)" % (time.time() - started, last), flush=True)
            ask_at = time.time() + 10
        if time.time() > end:
            break
    print("the save did not come back in %d s" % timeout)
    return 1


def game_process():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq ProjectZomboid64.exe", "/NH"], capture_output=True,
                         text=True, errors="replace", creationflags=0x08000000).stdout
    return "ProjectZomboid64.exe" in out


# Waits for the game's process to end after its window went: a game that writes a cache as it quits (PZ Optimize's
# Java AOT recording writes some hundred MB) runs on for a while, and Steam answers a start meanwhile with "the game
# is already running". Then a few seconds more for Steam to see it gone.
def process_gone(timeout=600):
    end = time.time() + timeout
    said = False
    while game_process():
        if time.time() > end:
            print("the game's process did not end in %d s" % timeout)
            return False
        if not said:
            print("waiting for the game's process to end")
            said = True
        time.sleep(1)
    if said:
        time.sleep(5)
    return True


# Sets keys of the game's options.ini; returns what they were for those it changed ({} when none or no file).
def set_options(want):
    try:
        with open(OPTIONS, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    was = {}
    for i, line in enumerate(lines):
        key, sep, value = line.partition("=")
        if sep and key in want and value != want[key]:
            was[key] = value
            lines[i] = key + "=" + want[key]
    if was:
        with open(OPTIONS, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
    return was


# The game's display options set to the window pzdev drives, before the game starts (it reads them only then); what the
# user had is kept in DISPLAY_KEPT (unless an earlier start's is there still) and put back by release() once the game
# ended (it writes its options as it quits from the main menu, the window pzdev gave it among them).
def windowed_options():
    was = set_options({"fullScreen": "false", "borderless": "false", "width": str(WINDOW[0]), "height": str(WINDOW[1])})
    if was and not os.path.exists(DISPLAY_KEPT):
        with open(DISPLAY_KEPT, "w", encoding="utf-8") as f:
            f.write("".join("%s=%s\n" % item for item in was.items()))
    if was:
        print("options set windowed for this start:", ", ".join("%s %s" % item for item in was.items()))


# Puts the user's display options back.
def restore_options():
    try:
        with open(DISPLAY_KEPT, encoding="utf-8") as f:
            kept = dict(line.split("=", 1) for line in f.read().splitlines() if "=" in line)
    except OSError:
        return
    set_options(kept)
    os.remove(DISPLAY_KEPT)
    print("the user's display options put back:", ", ".join("%s=%s" % item for item in kept.items()))


# With no game running: the user's display options and latest save back (what a guard missed, a reboot say).
def release():
    if game_process():
        return
    restore_options()
    put_latest_back()


# Waits for the game's process (its id) to end, then release(): started detached by start_game, so it outlives pzdev.
def guard(pid):
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
    if handle:
        kernel32.WaitForSingleObject(handle, 0xFFFFFFFF)
        kernel32.CloseHandle(handle)
    time.sleep(1)
    release()
    return 0


# Starts the game's exe with -debug (the dev channel needs it; Steam's launch no longer adds it), windowed.
def start_game():
    windowed_options()
    game = subprocess.Popen([os.path.join(GAME_DIR, "ProjectZomboid64.exe"), "-debug"], cwd=GAME_DIR,
                            creationflags=0x00000008 | 0x00000200, close_fds=True)
    # the guard: puts the user's options and latest save back as this game ends
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "guard", str(game.pid)], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=0x00000008 | 0x00000200, close_fds=True)


# The running game's command line ("" when none or unreadable).
def game_command_line():
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "(Get-CimInstance Win32_Process -Filter \"Name='ProjectZomboid64.exe'\").CommandLine"],
                         capture_output=True, text=True, errors="replace", creationflags=0x08000000).stdout
    return out.strip()


# Whether the game's window covers the whole screen (full screen or borderless at the screen's size).
def full_screen():
    left, top, right, bottom = window_rect(False)
    width, height = window_rect(True)[2:]
    return right - left >= width and bottom - top >= height


# Closes the game's window without the channel (a game on the main menu, or one without -debug) and waits for the process.
def close_window():
    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, "Project Zomboid")
    if hwnd:
        user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
    end = time.time() + 60
    while game_window() and time.time() < end:
        time.sleep(0.5)
    if game_window():
        subprocess.run(["taskkill", "/IM", "ProjectZomboid64.exe", "/F"], capture_output=True, creationflags=0x08000000)
    return process_gone()


# Starts the game when it is not running and gets into the latest save; returns when the channel answers there.
def launch():
    if game_window():
        if send('print("here")', 3, quiet=True) == 0:
            if SAVE and current_save() not in (None, SAVE):
                print("in another save: loading " + SAVE)
                return reload()
            print("already in a save")
            return 0
        # Without -debug the channel never answers: a game the user started (from Steam). Not closed: said at once.
        if "-debug" not in game_command_line():
            print("the game runs without -debug (started from Steam?): the channel is off. Close it, or `pzdev restart`"
                  " closes it and starts it with -debug")
            return 1
        # the window is there, the channel silent: still booting (the menu not built yet: Continue pressed now is lost),
        # loading a save, or on the main menu
        menu, load = console_last("binkId: "), console_last("STATE: exit zombie.gameStates.MainScreenState")
        if menu < 0:
            # whether its menu reads a latest save pzdev pointed is not known: Continue is pressed only where it did
            if not os.path.exists(LATEST_KEPT):
                print("the game is still starting, its Continue the user's: `pzdev restart --save <test save>`")
                return 1
            print("the game is still starting")
            return continue_when_ready(0)
        if load > menu:
            print("a save is loading")
            return until_loaded(240)
        # On the main menu at the screen's size: Continue is elsewhere; closed (no save is open) and started windowed.
        # With --save: the menu read its latest save already; closed and started again with it.
        if full_screen() or SAVE:
            print("the game is full screen on the main menu: closing it to start it windowed" if not SAVE else
                  "the main menu read its latest save already: closing it to start it with " + SAVE)
            if not close_window():
                return 1
            return launch()
        return continue_save()
    # a process without a window: a game still quitting (wait for it to end) or one just starting (its window comes)
    end, waited = time.time() + 600, False
    while game_process() and not game_window():
        if time.time() > end:
            print("the game's process did not end in 600 s")
            return 1
        if not waited:
            print("waiting for the game's process (quitting or starting)")
            waited = True
        time.sleep(1)
    if game_window():
        return launch()
    if waited:
        # Steam takes a few seconds to see the game gone
        time.sleep(5)
    if not SAVE:
        print(NO_SAVE)
        return 1
    start = console_size()
    point_latest(SAVE)
    start_game()
    print("starting the game")
    name, _ = wait_for({"menu", "exit"}, 300, start)
    if name != "menu":
        print("the main menu did not come in 5 minutes" if name is None else "the game closed while starting")
        return 1
    print("on the main menu")
    return continue_when_ready(start)


# Quits to the desktop (a paused game takes the command and never leaves: set going first) and waits for the window
# to go.
def quit_game():
    if game_window():
        if send("if isGamePaused() then setGameSpeed(1) end getCore():quitToDesktop()", 5, quiet=True) != 0:
            # no channel (no -debug, or on the main menu): the window is closed
            print("the channel is silent: closing the window")
            gone = close_window()
            release()
            return 0 if gone else 1
        end = time.time() + 90
        while game_window():
            if time.time() > end:
                print("the game did not close in 90 s")
                return 1
            time.sleep(0.5)
        print("closed")
        time.sleep(2)
    gone = process_gone()
    release()
    return 0 if gone else 1


def restart():
    return quit_game() or launch()


# Brings the game window to the front (a window over it would be in the picture) and gives it time to draw again.
def front():
    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, "Project Zomboid")
    if hwnd and user32.GetForegroundWindow() != hwnd:
        user32.SetForegroundWindow(hwnd)
        time.sleep(1.5)


# A picture of the game after `wait` seconds; `count` of them `every` seconds apart (path_1.png, path_2.png, ...).
def shot(path, wait, full, count=1, every=0.0):
    from PIL import ImageGrab
    front()
    time.sleep(wait)
    box = window_rect(full)
    stem, ext = os.path.splitext(path)
    for i in range(count):
        out = path if count == 1 else "%s_%d%s" % (stem, i + 1, ext)
        ImageGrab.grab(bbox=box, all_screens=True).save(out)
        print("saved", out, box)
        if i + 1 < count:
            time.sleep(every)
    return 0


def main():
    global SAVE
    if len(sys.argv) == 3 and sys.argv[1] == "guard":
        return guard(int(sys.argv[2]))
    SAVE = arg("--save") or os.environ.get("PZDEV_SAVE")
    release()
    timeout_s = arg("--timeout")
    timeout = float(timeout_s or "15")
    if len(sys.argv) == 2 and sys.argv[1] == "launch":
        return launch()
    if len(sys.argv) == 2 and sys.argv[1] == "quit":
        return quit_game()
    if len(sys.argv) == 2 and sys.argv[1] == "restart":
        return restart()
    if len(sys.argv) == 2 and sys.argv[1] == "watch":
        watch()
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "wait":
        wanted = sys.argv[2]
        name, detail = wait_for({wanted}, float(timeout_s or "300"))
        print((name + " " + detail).strip() if name else "no %s in time" % wanted)
        return 0 if name else 1
    wait = float(arg("--wait", "0"))
    follow_s = arg("--follow")
    full = "--full" in sys.argv
    if full:
        sys.argv.remove("--full")
    if len(sys.argv) == 2 and sys.argv[1] == "resume":
        return resume()
    if len(sys.argv) == 2 and sys.argv[1] == "reload":
        return reload()
    if len(sys.argv) == 2 and sys.argv[1] == "menu":
        return leave_save(console_size())
    if len(sys.argv) == 2 and sys.argv[1] == "continue":
        return continue_save()
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    what, value = sys.argv[1], sys.argv[2]
    after = float(follow_s) if follow_s else (3.0 if what == "check" else 0)
    start = console_size()
    if what == "run":
        code = value
    elif what == "file":
        with open(value, encoding="utf-8") as f:
            code = f.read()
    elif what == "check":
        code = 'RUN("%s")' % value
    else:
        code = None
    if code is not None:
        status = send(code, timeout)
        if after > 0:
            print("-- logged in the next %ss:" % after)
            # the lines the command printed itself come again: only those after its answer are new
            start = console_size()
            follow(start, after)
        return status
    if what == "shot":
        return shot(value, wait, full, int(arg("--count", "1")), float(arg("--every", "0.5")))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
