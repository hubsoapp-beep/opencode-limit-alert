#!/usr/bin/env python3
"""Banner z listą zadań OpenCode, które stanęły. Klik w zadanie przełącza na jego
kartę w herdr, Orca albo Ghostty. Bez zależności (stdlib + PyObjC z systemu).

Plugin limit-alert.js zapisuje każde zdarzenie jako plik JSON w ~/.opencode-alerts/
(jeden plik na sesję) i uruchamia `alerts.py show`. Ten proces trzyma okno, dopóki
w katalogu są alerty, i odświeża listę co sekundę.
"""
import argparse
import fcntl
import json
import os
import socket
import subprocess
import sys
from datetime import datetime
from pathlib import Path
import tempfile
import urllib.request
import urllib.error

SPOOL = Path.home() / ".opencode-alerts"
LOCK = SPOOL / ".show.lock"
SPEAK_LOCK = SPOOL / ".speak.lock"
LOG = Path("/tmp/opencode-alerts.log")
MAX_ROWS = 6

HERDR = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", str(Path.home() / ".local/bin/herdr")]
ORCA = ["/usr/local/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca", "/opt/homebrew/bin/orca"]

KINDS = {
    "limit": ("Skończył się limit", "hourglass", "systemOrangeColor"),
    "error": ("Zadanie stanęło", "exclamationmark.triangle.fill", "systemRedColor"),
    "done": ("Zadanie skończone", "checkmark.circle.fill", "systemGreenColor"),
}


def log(msg):
    try:
        with LOG.open("a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}\n")
    except OSError:
        pass


# ---------- spool ----------

def load_alerts():
    items = []
    for p in SPOOL.glob("*.json"):
        try:
            item = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(item, dict) and isinstance(item.get("sessionID"), str):
            item["_path"] = str(p)
            items.append(item)
    return sorted(items, key=lambda i: i.get("time", ""), reverse=True)


def remove_alert(item):
    try:
        import traceback
        caller = traceback.extract_stack()[-2]
        log(f"remove {item.get('id')} z {caller.name}:{caller.lineno}")
    except Exception:
        pass
    Path(item["_path"]).unlink(missing_ok=True)


# ---------- lokalizacja karty ----------

def first_exe(candidates):
    return next((c for c in candidates if os.access(c, os.X_OK)), None)


def run_json(args):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=5).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def norm(s):
    return " ".join((s or "").replace("…", "").split()).casefold()


def title_matches(window_title, session_title):
    """Terminal ucina długie tytuły ('OC | Długi tytuł…'), więc porównujemy prefiksy."""
    w = norm(window_title)
    if w.startswith("oc | "):
        w = w[5:]
    t = norm(session_title)
    if not w or not t:
        return False
    return w == t or (len(w) >= 12 and t.startswith(w)) or (len(t) >= 12 and w.startswith(t))


def find_herdr(panes, session_id, title):
    for pane in panes:
        if (pane.get("agent_session") or {}).get("value") == session_id:
            return pane
    for pane in panes:
        if title_matches(pane.get("terminal_title_stripped") or pane.get("label"), title):
            return pane
    return None


def find_orca(terminals, title):
    for t in terminals:
        if title_matches(t.get("title"), title):
            return t
    return None


def locate(item):
    """Zwraca (nazwa terminala, akcja) albo (None, None)."""
    sid, title = item.get("sessionID"), item.get("title", "")
    herdr = first_exe(HERDR)
    if herdr:
        data = run_json([herdr, "pane", "list"])
        panes = ((data or {}).get("result") or {}).get("panes") or []
        pane = find_herdr(panes, sid, title)
        if pane:
            return "herdr", lambda: focus_herdr(herdr, pane)
    orca = first_exe(ORCA)
    if orca:
        data = run_json([orca, "terminal", "list", "--json"])
        terms = ((data or {}).get("result") or {}).get("terminals") or []
        term = find_orca(terms, title)
        if term:
            return "Orca", lambda: focus_orca(orca, term)
    if title and ghostty_menu_item(title):
        return "Ghostty", lambda: click_ghostty(title)
    return None, None


def osascript(script):
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=10)
    if r.returncode:
        log(f"osascript: {r.stderr.strip()}")
    return r.stdout.strip()


def as_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def activate(app):
    # `open -a` bywa ignorowane z procesów w tle; AppleScript activate działa.
    osascript(f"tell application {as_str(app)} to activate")


def ghostty_menu_items():
    out = osascript('tell application "System Events" to tell process "Ghostty" to '
                    'get name of every menu item of menu "Window" of menu bar 1')
    return [n.strip() for n in out.split(", ") if n.strip() and n.strip() != "missing value"]


def ghostty_menu_item(title):
    return next((n for n in ghostty_menu_items() if title_matches(n, title)), None)


def click_ghostty_item(name):
    osascript(f'''tell application "Ghostty" to activate
tell application "System Events" to tell process "Ghostty"
  click menu item {as_str(name)} of menu "Window" of menu bar 1
end tell''')


def click_ghostty(title):
    name = ghostty_menu_item(title)
    if name:
        click_ghostty_item(name)
    else:
        activate("Ghostty")


def focus_herdr(herdr, pane):
    subprocess.run([herdr, "workspace", "focus", pane["workspace_id"]], capture_output=True, timeout=5)
    subprocess.run([herdr, "tab", "focus", pane["tab_id"]], capture_output=True, timeout=5)
    # Okno klienta herdr w Ghostty ma tytuł "<host>: <workspace>".
    host = socket.gethostname()
    name = next((n for n in ghostty_menu_items() if n.startswith(host)), None)
    if name:
        click_ghostty_item(name)
    else:
        activate("Ghostty")


def focus_orca(orca, term):
    subprocess.run([orca, "terminal", "switch", "--terminal", term["handle"]], capture_output=True, timeout=5)
    activate("Orca")


def jump(item):
    where, action = locate(item)
    log(f"jump {item.get('title')!r} -> {where}")
    if action:
        action()
    return where


# ---------- UI ----------

_UI = {}


def ui():
    """Klasy ObjC definiujemy RAZ — PyObjC nie pozwala redefiniować klasy o tej samej nazwie."""
    if _UI:
        return _UI
    from AppKit import NSButton, NSColor, NSView, NSWindow
    from Foundation import NSObject
    import objc

    class Btn(NSButton):
        def acceptsFirstMouse_(self, event):
            return True  # pierwszy klik działa bez aktywacji okna

    class KeyWindow(NSWindow):
        def canBecomeKeyWindow(self):
            return True

    class RowView(NSView):
        # cały wiersz klikalny + podświetlenie pod kursorem
        def acceptsFirstMouse_(self, event):
            return True

        def mouseDown_(self, event):
            if getattr(self, "on_click", None):
                self.on_click()

        def mouseEntered_(self, event):
            self.layer().setBackgroundColor_(NSColor.labelColor().colorWithAlphaComponent_(0.08).CGColor())

        def mouseExited_(self, event):
            self.layer().setBackgroundColor_(NSColor.clearColor().CGColor())

    class Target(NSObject):
        def initWithFn_(self, fn):
            self = objc.super(Target, self).init()
            self.fn = fn
            return self

        def fire_(self, sender):
            self.fn()

    _UI.update(Btn=Btn, KeyWindow=KeyWindow, RowView=RowView, Target=Target)
    return _UI


class Banner:
    BW, PAD, ROW_H = 382, 16, 50

    def __init__(self):
        from AppKit import NSApplication, NSBackingStoreBuffered
        from Foundation import NSMakeRect
        self.app = NSApplication.sharedApplication()
        self.app.setActivationPolicy_(1)  # Accessory — bez ikony w Docku
        self.win = ui()["KeyWindow"].alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, self.BW, 120), 0, NSBackingStoreBuffered, False)
        self.win.setReleasedWhenClosed_(False)
        self.win.setLevel_(101)  # nad oknami i fullscreenem
        self.win.setCollectionBehavior_((1 << 0) | (1 << 4) | (1 << 8))
        self.win.setOpaque_(False)
        self.win.setHasShadow_(True)
        from AppKit import NSColor
        self.win.setBackgroundColor_(NSColor.clearColor())
        self.keep = []      # referencje do targetów ObjC (inaczej GC je zabierze)
        self.where = {}     # cache: alert id → nazwa terminala
        self.shown = None
        self.empty_ticks = 0

    # --- budowanie widoku ---

    def text(self, rect, string, size, weight, color, align=0, wrap=False):
        from AppKit import NSFont, NSTextField
        f = NSTextField.alloc().initWithFrame_(rect)
        f.setStringValue_(string)
        f.setEditable_(False)
        f.setSelectable_(False)
        f.setBordered_(False)
        f.setDrawsBackground_(False)
        f.setAlignment_(align)
        f.setTextColor_(color)
        f.setFont_(NSFont.systemFontOfSize_weight_(size, weight))
        f.cell().setWraps_(wrap)
        f.cell().setLineBreakMode_(0 if wrap else 4)  # 4 = truncate tail
        return f

    def symbol(self, rect, name, color_name, size):
        from AppKit import NSColor, NSImage, NSImageSymbolConfiguration, NSImageView
        iv = NSImageView.alloc().initWithFrame_(rect)
        img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
        if img:
            cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_(size, 0.3)
            iv.setImage_(img.imageWithSymbolConfiguration_(cfg))
        iv.setContentTintColor_(getattr(NSColor, color_name)())
        return iv

    def button(self, cv, rect, label, fn, key="", prominent=False):
        from AppKit import NSColor, NSFont
        t = ui()["Target"].alloc().initWithFn_(fn)
        self.keep.append(t)
        b = ui()["Btn"].alloc().initWithFrame_(rect)
        b.setTitle_(label)
        b.setBezelStyle_(1)
        b.setFont_(NSFont.systemFontOfSize_(13))
        b.setTarget_(t)
        b.setAction_("fire:")
        b.setKeyEquivalent_(key)
        if prominent:
            # Okno nie kradnie fokusu, więc systemowy bezel byłby szary — rysujemy akcent sami.
            from AppKit import NSAttributedString, NSForegroundColorAttributeName, NSFontAttributeName
            b.setBordered_(False)
            b.setWantsLayer_(True)
            b.layer().setBackgroundColor_(NSColor.controlAccentColor().CGColor())
            b.layer().setCornerRadius_(6)
            r = rect
            b.setFrame_(((r.origin.x + 6, r.origin.y + 5), (r.size.width - 12, r.size.height - 10)))
            b.setAttributedTitle_(NSAttributedString.alloc().initWithString_attributes_(
                label, {NSForegroundColorAttributeName: NSColor.whiteColor(),
                        NSFontAttributeName: NSFont.systemFontOfSize_weight_(13, 0.23)}))
        cv.addSubview_(b)
        return b

    def row(self, cv, rect, item):
        from AppKit import NSColor, NSTrackingArea
        from Foundation import NSMakeRect
        label, sym, color = KINDS.get(item.get("kind"), KINDS["error"])
        r = ui()["RowView"].alloc().initWithFrame_(rect)
        r.setWantsLayer_(True)
        r.layer().setCornerRadius_(10)
        r.on_click = lambda: self.open(item)
        r.addTrackingArea_(NSTrackingArea.alloc().initWithRect_options_owner_userInfo_(
            r.bounds(), 0x01 | 0x80 | 0x200, r, None))
        w, h = rect.size.width, rect.size.height
        r.addSubview_(self.symbol(NSMakeRect(8, (h - 22) / 2, 22, 22), sym, color, 15))
        t = item.get("time", "")[11:16]
        where = self.where.get(item["id"])
        sub = " · ".join(x for x in (label, t, where) if x)
        r.addSubview_(self.text(NSMakeRect(38, h / 2 - 1, w - 38 - 30, 18),
                                item.get("title") or "bez nazwy", 13, 0.4, NSColor.labelColor()))
        r.addSubview_(self.text(NSMakeRect(38, h / 2 - 18, w - 38 - 30, 15),
                                sub, 11, 0, NSColor.secondaryLabelColor()))
        x = self.button(r, NSMakeRect(w - 28, (h - 22) / 2, 22, 22), "", lambda: self.dismiss(item))
        x.setBezelStyle_(7)  # bez ramki
        x.setBordered_(False)
        from AppKit import NSImage
        x.setImage_(NSImage.imageWithSystemSymbolName_accessibilityDescription_("xmark", "Odrzuć"))
        x.setContentTintColor_(NSColor.tertiaryLabelColor())
        cv.addSubview_(r)

    def build(self, items):
        from AppKit import NSColor, NSScreen, NSView, NSVisualEffectView, NSWorkspace
        from Foundation import NSMakeRect
        from Quartz import CGColorCreateGenericGray
        self.keep = []
        BW, PAD, ROW_H = self.BW, self.PAD, self.ROW_H
        visible = items[:MAX_ROWS]
        more = len(items) - len(visible)
        BH = PAD + 18 + 8 + len(visible) * ROW_H + (18 if more else 0) + 8 + 30 + 14

        vf = NSScreen.mainScreen().visibleFrame()
        self.win.setFrame_display_(NSMakeRect(vf.origin.x + vf.size.width - BW - PAD,
                                              vf.origin.y + vf.size.height - BH - 12, BW, BH), True)
        cv = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, BW, BH))
        self.win.setContentView_(cv)

        if not NSWorkspace.sharedWorkspace().accessibilityDisplayShouldReduceTransparency():
            bg = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, BW, BH))
            bg.setMaterial_(6)
            bg.setBlendingMode_(0)
            bg.setState_(1)
            bg.setWantsLayer_(True)
            bg.layer().setCornerRadius_(20)
            bg.layer().setMasksToBounds_(True)
            bg.layer().setBorderWidth_(0.5)
            bg.layer().setBorderColor_(CGColorCreateGenericGray(0.5, 0.25))
            cv.addSubview_(bg)
        else:
            cv.setWantsLayer_(True)
            cv.layer().setBackgroundColor_(NSColor.windowBackgroundColor().CGColor())
            cv.layer().setCornerRadius_(20)

        top = BH - PAD - 16
        cv.addSubview_(self.symbol(NSMakeRect(PAD, top - 2, 18, 18), "terminal.fill", "secondaryLabelColor", 13))
        n = len(items)
        head = "OPENCODE" if n == 1 else f"OPENCODE · {n} ZADANIA" if n < 5 else f"OPENCODE · {n} ZADAŃ"
        cv.addSubview_(self.text(NSMakeRect(PAD + 24, top, 240, 15), head, 11, 0.3,
                                 NSColor.secondaryLabelColor()))
        cv.addSubview_(self.text(NSMakeRect(BW - PAD - 52, top, 52, 15), datetime.now().strftime("%H:%M"),
                                 11, 0, NSColor.tertiaryLabelColor(), align=2))

        y = top - 8
        for item in visible:
            y -= ROW_H
            self.row(cv, NSMakeRect(PAD - 6, y, BW - 2 * PAD + 12, ROW_H - 4), item)
        if more:
            y -= 18
            cv.addSubview_(self.text(NSMakeRect(PAD + 32, y, 200, 15), f"+{more} więcej",
                                     11, 0, NSColor.tertiaryLabelColor()))

        if n == 1:
            bw = (BW - PAD * 2 - 8) / 2
            self.button(cv, NSMakeRect(PAD, 14, bw, 30), "Odrzuć", lambda: self.dismiss(items[0]), "\x1b")
            self.button(cv, NSMakeRect(PAD + bw + 8, 14, bw, 30), "Przejdź",
                        lambda: self.open(items[0]), "\r", prominent=True)
        else:
            self.button(cv, NSMakeRect(PAD, 14, BW - 2 * PAD, 30), "Wyczyść wszystko", self.clear_all, "\x1b")

    # --- akcje ---

    def open(self, item):
        remove_alert(item)
        self.win.orderOut_(None)  # schowaj, żeby nie zasłaniał terminala
        try:
            jump(item)
        except Exception as e:  # noqa: BLE001 — UI nie może paść przez terminal
            log(f"jump error: {e}")
        self.refresh(force=True)

    def dismiss(self, item):
        remove_alert(item)
        self.refresh(force=True)

    def clear_all(self):
        for item in load_alerts():
            remove_alert(item)
        self.refresh(force=True)

    def refresh(self, force=False):
        items = load_alerts()
        if not items:
            self.win.orderOut_(None)
            self.empty_ticks += 1
            if self.empty_ticks >= 2:
                self.app.terminate_(None)
            return
        self.empty_ticks = 0
        for item in items:
            item.setdefault("id", item["_path"])
            if item["id"] not in self.where:
                try:
                    self.where[item["id"]] = locate(item)[0]
                except Exception as e:  # noqa: BLE001
                    log(f"locate error: {e}")
                    self.where[item["id"]] = None
        key = [(i["id"], i.get("time"), i.get("kind")) for i in items]
        if force or key != self.shown or not self.win.isVisible():
            self.shown = key
            self.build(items)
            self.win.orderFrontRegardless()  # bez kradzieży fokusu z klawiatury

    def run(self):
        from Foundation import NSTimer
        t = ui()["Target"].alloc().initWithFn_(self.refresh)
        self.keep_timer = t
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, t, "fire:", None, True)
        self.app.finishLaunching()
        self.refresh(force=True)
        self.app.run()


def show():
    SPOOL.mkdir(exist_ok=True)
    with LOCK.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # banner już działa i sam wczyta nowy alert
        log("show start")
        Banner().run()
    # Alert mógł wpaść między zamknięciem okna a zwolnieniem locka.
    if load_alerts():
        os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve()), "show"])



# ---------- konfiguracja / mowa ----------

CONFIG_PATH = Path.home() / ".config/opencode/limit-alert.json"


def app_running():
    """Czy działa LimitAlert.app? Wtedy to ona pokazuje baner i czyta alert."""
    try:
        pid = int((SPOOL / ".app.pid").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        pid = 0
    if pid:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            pass
    # Zawodnik może zniknąć — wtedy ten skrypt i aplikacja gadają równocześnie
    # i słychać podwójny głos. Sprawdzamy więc też proces po nazwie.
    return subprocess.run(["/usr/bin/pgrep", "-x", "LimitAlert"],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def load_config():
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    return {
        "apiKey": data.get("elevenlabsApiKey") or os.environ.get("ELEVENLABS_API_KEY", ""),
        "voiceId": data.get("voiceId") or "EXAVITQu4vr4xnSDxMaL",
        "modelId": data.get("modelId") or "eleven_flash_v2_5",
        "systemVoice": data.get("systemVoice") or "Zosia",
        "voiceByAgent": data.get("voiceByAgent") or {},
        "announceDone": data.get("announceDone", True) is not False,
    }


def speak_text(text, agent=""):
    """Czyta tekst, czekając aż poprzednie czytanie się skończy.

    Banner ma własną kolejkę, ale `alerts.py speak/alert` może być uruchomiony
    równolegle z kilku procesów — lock sprawia, że głosy się nie nakładają.
    """
    SPOOL.mkdir(exist_ok=True)
    with SPEAK_LOCK.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _speak_text(text, agent)


def _speak_text(text, agent=""):
    cfg = load_config()
    api_key = cfg["apiKey"]
    voice_id = cfg["voiceByAgent"].get(agent) or cfg["voiceId"]
    if api_key:
        try:
            url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128"
            payload = json.dumps({"text": text, "model_id": cfg["modelId"]}).encode("utf-8")
            req = urllib.request.Request(url, data=payload, headers={
                "xi-api-key": api_key, "content-type": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as r:
                audio = r.read()
            fd, path = tempfile.mkstemp(suffix=".mp3")
            os.close(fd)
            Path(path).write_bytes(audio)
            played = subprocess.run(["/usr/bin/afplay", path], timeout=60).returncode == 0
            Path(path).unlink(missing_ok=True)
            if played:
                return
        except Exception as e:
            log(f"elevenlabs failed: {e}")
    system_voice = cfg["systemVoice"]
    # Nigdy `say` bez -v: domyślny głos macOS (Alex, EN męski) brzmiałby jak
    # inny lektor. Gdy wskazany głos zawiedzie — lepiej cisza.
    if system_voice:
        subprocess.run(["/usr/bin/say", "-v", system_voice, text])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("show", help="pokaż banner (gdy są alerty)")
    sub.add_parser("list", help="wypisz alerty")
    sub.add_parser("clear", help="usuń wszystkie alerty")
    add = sub.add_parser("add", help="dodaj testowy alert")
    spk = sub.add_parser("speak", help="powiedz tekst (ElevenLabs/say)")
    spk.add_argument("text")
    al = sub.add_parser("alert", help="dodaj alert + przeczytaj")
    al.add_argument("title")
    al.add_argument("--kind", default="limit", choices=sorted(KINDS))
    al.add_argument("--session", default="")
    al.add_argument("--detail", default="")
    al.add_argument("--agent", default="")
    add.add_argument("title")
    add.add_argument("--kind", default="limit", choices=sorted(KINDS))
    add.add_argument("--session", default="")
    jmp = sub.add_parser("jump", help="przełącz na kartę zadania (test)")
    jmp.add_argument("title")
    jmp.add_argument("--session", default="")
    args = parser.parse_args()

    if args.cmd == "speak":
        speak_text(args.text)
    elif args.cmd == "alert":
        SPOOL.mkdir(exist_ok=True)
        sid = args.session or f"{args.agent or 'alert'}-{datetime.now():%H%M%S%f}"
        sid = "".join(c if c.isalnum() or c in "._-" else "_" for c in sid)
        heading = KINDS[args.kind][0]
        item = {"id": sid, "sessionID": sid, "title": args.title, "kind": args.kind,
                "detail": args.detail, "agent": args.agent,
                "time": datetime.now().isoformat(timespec="seconds")}
        (SPOOL / f"{sid}.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
        print(f"✔ {args.title}")
        # Gdy działa LimitAlert.app, ona odczyta plik i sama przeczyta alert.
        if app_running():
            return
        # uruchom banner (w tle)
        try:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "show"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except Exception:
            pass
        speak_text(f"{heading}. Zadanie: {args.title}.", args.agent)
    elif args.cmd == "show":
        show()
    elif args.cmd in (None, "list"):
        items = load_alerts()
        print("\n".join(f"{i.get('time', '')[:16]}  {i.get('kind')}  {i.get('title')}" for i in items)
              if items else "(pusto)")
    elif args.cmd == "clear":
        for item in load_alerts():
            remove_alert(item)
    elif args.cmd == "add":
        SPOOL.mkdir(exist_ok=True)
        sid = args.session or f"test-{datetime.now():%H%M%S%f}"
        item = {"id": sid, "sessionID": sid, "title": args.title, "kind": args.kind,
                "time": datetime.now().isoformat(timespec="seconds")}
        (SPOOL / f"{sid}.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
        print(f"✔ {args.title}")
    elif args.cmd == "jump":
        print(jump({"sessionID": args.session, "title": args.title}) or "nie znaleziono karty")


if __name__ == "__main__":
    main()
