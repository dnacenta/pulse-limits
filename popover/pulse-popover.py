#!/usr/bin/env python3
# PulsePopover for Linux: the monitor page as a drop-down under Waybar, the counterpart of
# PulsePopover.swift. A borderless WebKit surface on the wlr layer shell, anchored to the
# bar's edge on the module's side. It never grabs input: the keyboard is its only once
# clicked into, so the desktop stays usable while it is open; a second click on the bar item
# hides it, and so does Escape once it has the keyboard.
#
#   pulse-popover [width] [height] [pulse-limits]
#   pulse-popover --check        can this session show it? one line, exit 0 or 1
#
# Resident like the Swift one: the first launch shows it and writes popover.pid; SIGUSR1
# toggles it (`pulse-limits open` sends it); hidden, the page is unloaded, and after
# PULSE_IDLE_EXIT seconds hidden (default 600) the process exits. Reads
# $XDG_CACHE_HOME/pulse-limits/panel.url on every show. While shown it runs `pulse-limits
# payload` every 2 min -> window.pulse.usage(...), and `pulse-limits activity` every 2 s
# (plus `estimate` every 10 s for Claude) -> window.pulse.activity(...).
#
# Needs PyGObject with GTK 3, WebKit2GTK 4.1 and gtk-layer-shell. Without them, or on a
# compositor without the layer shell (GNOME), or on X11, it opens the page in the browser,
# through the redirect file `pulse-limits open` writes, as before.
#
# The binary runs on GLib's own async subprocesses, never on Python threads: next to
# WebKit's threads those deadlocked the main loop after a while.

import json
import os
import re
import signal
import subprocess
import sys
import time

# WebKit's DMA-BUF renderer trips explicit sync on NVIDIA (the compositor drops the client
# with wp_linux_drm_syncobj "Missing acquire timeline"); the shared-memory path works on all.
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "pulse-limits")
URL_FILE = os.path.join(CACHE, "panel.url")
PID_FILE = os.path.join(CACHE, "popover.pid")
OPENER = os.path.join(CACHE, "open.html")  # the browser fallback `pulse-limits open` writes
WAYBAR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "waybar")
IDLE_EXIT = float(os.environ.get("PULSE_IDLE_EXIT") or 600)
GAP, SIDE_GAP = 6, 8  # from the bar (margins start past its exclusive zone) and from the screen side

# The page paints a square bezel on <body>. Round it; html needs a background image, even a
# transparent one, or body's background propagates to the whole canvas and is never clipped.
PAGE_CSS = "html { background: linear-gradient(transparent, transparent) !important; } body { border-radius: 16px; }"


def load_gtk():
    """The GI modules, or the reason they are missing."""
    try:
        import gi

        for ns, ver in (("Gtk", "3.0"), ("Gdk", "3.0"), ("WebKit2", "4.1"), ("GtkLayerShell", "0.1")):
            gi.require_version(ns, ver)
        from gi.repository import Gdk, Gio, GLib, Gtk, GtkLayerShell, WebKit2
    except (ImportError, ValueError) as e:
        return None, str(e) or "PyGObject"
    return (Gdk, Gio, GLib, Gtk, GtkLayerShell, WebKit2), ""


def browser():
    """The old way: the page in the browser."""
    if os.path.exists(OPENER):
        subprocess.Popen(["xdg-open", OPENER], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


def placement():
    """Which screen edge the bar is on and which side of it holds the module, from the
    Waybar config. JSONC, maybe several bars: good enough to look for the two keys."""
    text = ""
    for name in ("config.jsonc", "config"):
        try:
            with open(os.path.join(WAYBAR, name)) as f:
                text = f.read()
            break
        except OSError:
            pass
    m = re.search(r'"position"\s*:\s*"(top|bottom|left|right)"', text)
    edge = m.group(1) if m else "top"
    m = re.search(r'"modules-(left|center|right)"\s*:\s*\[[^\]]*"custom/pulse-limits"', text)
    side = m.group(1) if m else "right"
    return os.environ.get("PULSE_POPOVER_EDGE", edge), os.environ.get("PULSE_POPOVER_SIDE", side)


def resident():
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def main(argv):
    mods, missing = load_gtk()
    if argv[1:2] == ["--check"]:
        if mods is None:
            print(f"missing {missing}: the monitor opens in the browser")
            return 1
        Gtk, GtkLayerShell = mods[3], mods[4]
        if not Gtk.init_check(argv)[0]:
            print("GTK, WebKit2GTK and gtk-layer-shell found; no display to check the layer shell on")
            return 0
        if not GtkLayerShell.is_supported():
            print("this compositor has no layer shell (GNOME?): the monitor opens in the browser")
            return 1
        print("GTK, WebKit2GTK and gtk-layer-shell: the monitor drops down from the bar")
        return 0

    pid = resident()
    if pid:
        os.kill(pid, signal.SIGUSR1)
        return 0
    if mods is None or not os.environ.get("WAYLAND_DISPLAY"):
        return browser()
    Gdk, Gio, GLib, Gtk, GtkLayerShell, WebKit2 = mods
    if not Gtk.init_check(argv)[0] or not GtkLayerShell.is_supported():
        return browser()

    width = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 520
    height = int(argv[2]) if len(argv) > 2 and argv[2].isdigit() else 316
    pulse_bin = argv[3] if len(argv) > 3 else "pulse-limits"

    def pulse(args, done):
        """One run of the binary, off the main loop; done(one JSON document or None) on it."""
        try:
            proc = Gio.Subprocess.new([pulse_bin, *args], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            done(None)
            return

        def finished(p, res):
            try:
                _ok, out, _err = p.communicate_utf8_finish(res)
            except GLib.Error:
                done(None)
                return
            text = (out or "").strip()
            obj = None
            if p.get_exit_status() == 0 and text.startswith("{"):
                try:
                    obj = json.loads(text)
                except ValueError:
                    pass
            done(obj)

        proc.communicate_utf8_async(None, None, finished)

    class Popover:
        def __init__(self):
            E = GtkLayerShell.Edge
            edges = {"top": E.TOP, "bottom": E.BOTTOM, "left": E.LEFT, "right": E.RIGHT}
            bar_edge, side = placement()
            self.win = win = Gtk.Window()
            GtkLayerShell.init_for_window(win)
            GtkLayerShell.set_namespace(win, "pulse-limits")
            GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
            GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.ON_DEMAND)
            # Hug the bar's edge; along it, the module's side (centre: no anchor, centred).
            GtkLayerShell.set_anchor(win, edges[bar_edge], True)
            GtkLayerShell.set_margin(win, edges[bar_edge], GAP)
            along = {"left": "top", "center": None, "right": "bottom"} if bar_edge in ("left", "right") else {"left": "left", "center": None, "right": "right"}
            if along.get(side):
                GtkLayerShell.set_anchor(win, edges[along[side]], True)
                GtkLayerShell.set_margin(win, edges[along[side]], SIDE_GAP)
            visual = win.get_screen().get_rgba_visual()
            if visual:
                win.set_visual(visual)
            win.set_app_paintable(True)
            win.set_size_request(width, height)
            win.connect("draw", self.clear)
            win.connect("key-press-event", self.on_key)

            self.web = WebKit2.WebView()
            self.web.set_background_color(Gdk.RGBA(0, 0, 0, 0))
            self.web.get_settings().set_allow_file_access_from_file_urls(True)
            self.web.get_user_content_manager().add_style_sheet(
                WebKit2.UserStyleSheet(PAGE_CSS, WebKit2.UserContentInjectedFrames.TOP_FRAME, WebKit2.UserStyleLevel.USER, None, None)
            )
            self.web.connect("load-changed", self.on_load)
            win.add(self.web)

            self.visible = False
            self.hidden_at = time.time()
            self.timers = []
            self.provider = "claude"  # whose activity the live lane follows
            self.reading = None  # (pct, fetched) of Claude's session, for the dead-reckoned estimate
            self.estimate = None
            self.estimate_at = 0.0
            self.fetching = self.measuring = False

            try:
                from gi.repository import GLibUnix

                add_signal = GLibUnix.signal_add
            except ImportError:
                add_signal = GLib.unix_signal_add
            add_signal(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self.toggle)
            add_signal(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.quit)
            GLib.timeout_add_seconds(30, self.idle_check)

        @staticmethod
        def clear(_w, cr):
            cr.set_source_rgba(0, 0, 0, 0)
            cr.set_operator(1)  # cairo.OPERATOR_SOURCE: transparent corners
            cr.paint()
            return False

        def toggle(self):
            self.hide() if self.visible else self.show()
            return True

        def show(self):
            if self.visible:
                return
            try:
                with open(URL_FILE) as f:
                    url = f.read().strip()
            except OSError:
                return
            if not url:
                return
            self.visible = True
            self.web.load_uri(url)
            self.win.show_all()

        def on_load(self, _web, event):
            if event != WebKit2.LoadEvent.FINISHED or not self.visible or self.timers:
                return
            if not (self.web.get_uri() or "").startswith("file:"):
                return  # the about:blank unload also lands here
            self.push_activity()
            self.refresh_usage()
            self.timers = [
                GLib.timeout_add_seconds(2, lambda: self.push_activity() or True),
                GLib.timeout_add_seconds(120, lambda: self.refresh_usage() or True),
            ]

        def js(self, fn, obj):
            if not self.visible:
                return
            script = f"window.pulse && window.pulse.{fn}({json.dumps(obj)})"
            if hasattr(self.web, "evaluate_javascript"):
                self.web.evaluate_javascript(script, -1, None, None, None, None, None)
            else:
                self.web.run_javascript(script, None, None, None)

        def refresh_usage(self):
            if not self.visible or self.fetching:
                return
            self.fetching = True

            def done(obj):
                self.fetching = False
                if obj is None or not self.visible:
                    return
                self.provider = obj.get("provider") or "claude"
                # Dead reckoning is calibrated on Claude Code's transcripts: only Claude's session gets it.
                session = next((w for w in obj.get("windows") or [] if w.get("label") == "SESSION"), None)
                if self.provider == "claude" and session and "pct" in session and "fetched" in obj:
                    self.reading = (float(session["pct"]), int(obj["fetched"]))
                else:
                    self.reading = self.estimate = None
                self.estimate_at = 0.0
                self.js("usage", obj)
                self.push_activity()

            pulse(["payload"], done)

        def push_activity(self):
            if not self.visible or self.measuring:
                return
            self.measuring = True
            reading, provider = self.reading, self.provider
            due = time.time() - self.estimate_at >= 10  # the estimate scans minutes of transcripts

            def done(act, est):
                self.measuring = False
                if act is None or not self.visible:
                    return
                if est is not None:
                    self.estimate, self.estimate_at = est, time.time()
                if reading and self.estimate:
                    act["estimate"] = self.estimate
                self.js("activity", act)

            def got_activity(act):
                if act is not None and reading and due:
                    pct = reading[0]
                    pulse(["estimate", str(int(pct)) if pct == int(pct) else str(pct), str(reading[1])], lambda est: done(act, est))
                else:
                    done(act, None)

            pulse(["activity", provider], got_activity)

        def on_key(self, _w, ev):
            if ev.keyval == Gdk.KEY_Escape:
                self.hide()
                return True
            return False

        def hide(self):
            if not self.visible:
                return
            self.visible = False
            self.hidden_at = time.time()
            for t in self.timers:
                GLib.source_remove(t)
            self.timers = []
            self.win.hide()
            self.web.load_uri("about:blank")  # stop the animation, drop the page

        def idle_check(self):
            if not self.visible and time.time() - self.hidden_at > IDLE_EXIT:
                self.quit()
            return True

        def quit(self):
            try:
                os.unlink(PID_FILE)
            except OSError:
                pass
            os._exit(0)  # WebKit's threads can hold up interpreter shutdown; nothing to flush

    os.makedirs(CACHE, exist_ok=True)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    Popover().show()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
