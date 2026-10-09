#!/usr/bin/env python3
"""Drives a running game (started with -debug) through the mod's command channel (client/OperationAcorn/Dev/Remote.lua):
no typing into the Lua console. Single player; the helpers in Dev/Dev.lua (OperationAcorn.Dev) change the save.

Usage:
    python tools/pzdev.py run "OperationAcorn.Dev.state()"     runs Lua in the game, prints what it printed
    python tools/pzdev.py file path/to/script.lua             runs a Lua file the same way
    python tools/pzdev.py check p3_window.lua                 RUN()s an in-game check of tests/ingame, prints its lines
    python tools/pzdev.py shot out.png [--wait 2] [--full]    a picture of the game window (its inside only, or the
                                                              whole screen with --full) after waiting
    python tools/pzdev.py reload                              leaves the save to the main menu and continues it (Lua and
                                                              translations are read again; textures need a restart)
    python tools/pzdev.py continue                            from the main menu (after a game start), continues the
                                                              latest save and waits for it
    python tools/pzdev.py resume                            presses Resume in the game's Lua debugger (with Break On
                                                              Error, any Lua error, even one a pcall catches, stops the
                                                              game there, and the channel with it)
Options of run/file/check: --timeout seconds (default 15); --follow seconds: then also print the Lua lines the game
logs for that long (what a check prints a few ticks later; check follows 3 s by default).
Exit status 1 when the command failed in the game or no answer came (the game not running, not in -debug, or
still loading).
"""
import ctypes
import os
import sys
import time

ZOMBOID = os.path.join(os.path.expanduser("~"), "Zomboid", "Lua", "oadev")
CONSOLE = os.path.join(os.path.expanduser("~"), "Zomboid", "console.txt")
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
    while time.time() < end:
        time.sleep(0.1)
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


# Places from the top left of the game window's inside (the windowed 1280x720 game): Resume in the Lua debugger's
# tool bar, Continue on the main menu.
RESUME_AT = (564, 21)
CONTINUE_AT = (84, 56)


def click(at):
    user32 = ctypes.windll.user32
    left, top, _, _ = window_rect(False)
    hwnd = user32.FindWindowW(None, "Project Zomboid")
    # a window that was not in front: the game draws a few frames a second until it is, and misses a click in one
    settle = 0.3 if user32.GetForegroundWindow() == hwnd else 1.5
    user32.SetForegroundWindow(hwnd)
    time.sleep(settle)
    user32.SetCursorPos(left + at[0], top + at[1])
    time.sleep(0.15)
    # down and up several frames apart: the game reads the mouse once a frame and misses a click within one
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.25)
    user32.mouse_event(0x0004, 0, 0, 0, 0)


def resume():
    click(RESUME_AT)
    print("pressed resume")
    return 0


# Leaves the save to the main menu (the game saves it) and continues it: Lua and translations are read again (not
# textures). Returns when the channel answers in the loaded save.
def reload():
    if send("getCore():exitToMenu()", 15) != 0:
        return 1
    time.sleep(25)
    return continue_save()


# Whether the game logged anything but pzopt's input latch lines after `start` (a byte offset of console.txt): the menu
# logs nothing else while it waits, and a load starts with the save's mods.
def console_moved(start):
    try:
        with open(CONSOLE, "rb") as f:
            f.seek(start)
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return False
    return any(line.strip() and "input latch" not in line for line in text.splitlines())


# Presses Continue on the main menu (again while the game shows no sign of loading: a click can be missed) and returns
# when the channel answers in the loaded save.
def continue_save():
    for attempt in range(3):
        before = console_size()
        click(CONTINUE_AT)
        waited = time.time() + 12
        while time.time() < waited and not console_moved(before):
            time.sleep(1)
        if console_moved(before):
            break
        print("Continue was not taken; pressing it again")
    else:
        print("the game did not take Continue (is it on the main menu?)")
        return 1
    end = time.time() + 180
    seen = console_size()
    while time.time() < end:
        time.sleep(5)
        if send('print("loaded")', 5, quiet=True) == 0:
            print("reloaded")
            return 0
        # a Lua error while loading (vanilla's too) stops the load in the debugger: report it and go on
        size = console_size()
        if size > seen:
            with open(CONSOLE, "rb") as f:
                f.seek(seen)
                new = f.read().decode("utf-8", errors="replace")
            seen = size
            thrown = [l.strip() for l in new.splitlines() if "Exception thrown" in l]
            if thrown:
                print("a Lua error stopped the load:", thrown[0])
                click(RESUME_AT)
    print("the save did not come back in 3 minutes")
    return 1


def shot(path, wait, full):
    from PIL import ImageGrab
    time.sleep(wait)
    box = window_rect(full)
    ImageGrab.grab(bbox=box, all_screens=True).save(path)
    print("saved", path, box)
    return 0


def main():
    timeout = float(arg("--timeout", "15"))
    wait = float(arg("--wait", "0"))
    follow_s = arg("--follow")
    full = "--full" in sys.argv
    if full:
        sys.argv.remove("--full")
    if len(sys.argv) == 2 and sys.argv[1] == "resume":
        return resume()
    if len(sys.argv) == 2 and sys.argv[1] == "reload":
        return reload()
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
        return shot(value, wait, full)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
