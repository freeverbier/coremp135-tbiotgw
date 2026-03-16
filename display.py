#!/usr/bin/env python3
"""
CoreMP135 — IoT Gateway Status Display
Direct framebuffer rendering — no SDL, no X11, no Wayland.

Dependencies: python3-pil  python3-evdev
  apt install python3-pil python3-evdev

Framebuffer: /dev/fb1  (320×240, auto-detected bit depth)
Touch input: /dev/input/event0  (FocalTech FT6336U via evdev)

Layout (320×240):
  ┌─────────────────────────────────┐  y=0
  │   coremp135-xx-xx  CoreMP135    │  title bar (26px)
  ├─────────────────────────────────┤  y=28
  │ ▌ ThingsBoard    CONNECTED      │  row 38px
  ├─────────────────────────────────┤
  │ ▌ Tailscale      CONNECTED  IP  │  row 38px
  ├─────────────────────────────────┤
  │ ▌ eth0           192.168.x.x    │  row 38px
  ├─────────────────────────────────┤
  │   up 3d 14h    refreshed 09:21  │  info strip (20px)
  ├──────────────────┬──────────────┤
  │  [ Screen OFF ]  │  [ Refresh ] │  buttons (36px)
  └─────────────────────────────────┘  y=240
"""

import os
import sys
import json
import time
import struct
import socket
import threading
import subprocess
from pathlib import Path

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Missing: apt install python3-pil")
    sys.exit(1)

try:
    import evdev
    from evdev import InputDevice, categorize, ecodes
    HAS_EVDEV = True
except ImportError:
    HAS_EVDEV = False
    print("[WARN] evdev not found — touch disabled. apt install python3-evdev")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCREEN_W          = 320
SCREEN_H          = 240
FB_DEVICE         = "/dev/fb1"
TOUCH_DEVICE      = "/dev/input/event0"
REFRESH_INTERVAL  = 15        # seconds
BACKLIGHT_GLOB    = "/sys/class/backlight/*/brightness"

# Colours (RGB tuples)
BLACK   = (  0,   0,   0)
WHITE   = (255, 255, 255)
GREEN   = (  0, 200,  80)
RED     = (220,  50,  50)
YELLOW  = (230, 180,   0)
BLUE    = ( 30, 120, 255)
GRAY    = ( 90,  90,  90)
DARK    = ( 18,  18,  18)
PANEL   = ( 38,  38,  38)
PANEL2  = ( 28,  28,  28)

# ---------------------------------------------------------------------------
# Framebuffer writer
# ---------------------------------------------------------------------------
class Framebuffer:
    """Writes a PIL image to /dev/fb1, handles RGB565 and ARGB8888."""

    def __init__(self, device=FB_DEVICE):
        self.device = device
        self.bpp    = int(self._read_sysfs("bits_per_pixel", default="16"))
        w, h        = self._read_sysfs("virtual_size", default="320,240").split(",")
        self.width  = int(w)
        self.height = int(h)
        # stride = bytes per line (may include padding)
        stride_raw  = self._read_sysfs("stride", default=None)
        if stride_raw:
            self.stride = int(stride_raw)
        else:
            self.stride = self.width * (self.bpp // 8)
        self.fb_size = self.stride * self.height
        print(f"[FB] {device}  {self.width}×{self.height}  {self.bpp}bpp  stride={self.stride}  total={self.fb_size}B")

    def _fb_name(self):
        return Path(self.device).name   # e.g. "fb1"

    def _read_sysfs(self, attr, default=None):
        p = f"/sys/class/graphics/{self._fb_name()}/{attr}"
        try:
            return Path(p).read_text().strip()
        except Exception:
            return default

    def write(self, img: Image.Image):
        """Write PIL Image (RGB) to framebuffer."""
        img = img.convert("RGB").resize((self.width, self.height))
        if self.bpp == 16:
            data = self._to_rgb565_strided(img)
        else:
            data = self._to_rgb32_strided(img)
        try:
            with open(self.device, "rb+") as fb:
                fb.seek(0)
                fb.write(data)
        except PermissionError:
            print(f"[FB] Permission denied on {self.device} — run as root")
        except Exception as e:
            print(f"[FB] Write error: {e}")

    def _to_rgb565_strided(self, img):
        import array as arr
        pixels  = img.load()
        bpl     = self.stride          # bytes per line in the framebuffer
        ppline  = bpl // 2             # pixels per line (16bpp = 2 bytes/pixel)
        buf     = arr.array("H", [0] * (ppline * self.height))
        for y in range(img.height):
            row_off = y * ppline
            for x in range(img.width):
                r, g, b = pixels[x, y][:3]
                buf[row_off + x] = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        return buf.tobytes()

    def _to_rgb32_strided(self, img):
        """XRGB8888 (32bpp) with stride support."""
        out    = bytearray(self.fb_size)
        pixels = img.load()
        bpl    = self.stride
        for y in range(img.height):
            for x in range(img.width):
                r, g, b  = pixels[x, y][:3]
                off      = y * bpl + x * 4
                out[off:off+4] = struct.pack("<BBBB", b, g, r, 0xFF)
        return bytes(out)

    def clear(self, color=(0, 0, 0)):
        img = Image.new("RGB", (self.width, self.height), color)
        self.write(img)

# ---------------------------------------------------------------------------
# Backlight
# ---------------------------------------------------------------------------
def _find_backlight():
    import glob
    paths = glob.glob(BACKLIGHT_GLOB)
    return paths[0] if paths else None

_BL_PATH = _find_backlight()

def set_backlight(on: bool):
    if not _BL_PATH:
        return
    try:
        max_p = _BL_PATH.replace("brightness", "max_brightness")
        val   = Path(max_p).read_text().strip() if on else "0"
        Path(_BL_PATH).write_text(val)
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Status collectors
# ---------------------------------------------------------------------------
def _run(cmd, timeout=4):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except Exception:
        return -1, ""

def get_tailscale_status():
    rc, out = _run(["tailscale", "status", "--json"])
    if rc != 0:
        return "error", None
    try:
        d     = json.loads(out)
        state = d.get("BackendState", "")
        if state == "Running":
            _, ip = _run(["tailscale", "ip", "-4"])
            return "connected", ip.strip()
        return "disconnected", None
    except Exception:
        return "error", None

def get_tb_status():
    rc, out = _run(["docker", "inspect", "--format", "{{.State.Status}}", "tb-gateway"])
    if rc != 0 or "running" not in out:
        return "stopped"
    _, logs = _run(["docker", "logs", "--tail", "80", "tb-gateway"], timeout=6)
    logs = logs.lower()
    if any(k in logs for k in ("connected to thingsboard", "gateway connected",
                                "provisioning was successful", "[connected]")):
        return "connected"
    if "provision" in logs:
        return "provisioning"
    if any(k in logs for k in ("error", "exception", "refused", "timeout")):
        return "error"
    return "running"

def get_eth0_ip():
    rc, out = _run(["ip", "-4", "addr", "show", "eth0"])
    for line in out.splitlines():
        if "inet " in line and "169.254" not in line:
            return line.strip().split()[1].split("/")[0]
    return "unknown"

def get_uptime():
    try:
        secs = float(Path("/proc/uptime").read_text().split()[0])
        d    = int(secs // 86400)
        h    = int((secs % 86400) // 3600)
        m    = int((secs % 3600) // 60)
        return f"{d}d {h}h {m}m" if d else f"{h}h {m}m"
    except Exception:
        return "?"

# ---------------------------------------------------------------------------
# Font loader — tries system fonts, falls back to PIL default
# ---------------------------------------------------------------------------
def load_font(size, bold=False):
    candidates = [
        f"/usr/share/fonts/truetype/dejavu/DejaVuSansMono{'-Bold' if bold else ''}.ttf",
        f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf",
        f"/usr/share/fonts/truetype/liberation/LiberationMono-{'Bold' if bold else 'Regular'}.ttf",
        f"/usr/share/fonts/truetype/liberation/LiberationSans-{'Bold' if bold else 'Regular'}.ttf",
        "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                f = ImageFont.truetype(path, size)
                print(f"[FONT] Loaded {path} @{size}px")
                return f
            except Exception:
                pass
    print(f"[FONT] No TTF found for size={size}, using default (text may be tiny)")
    return ImageFont.load_default()

# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------
class Renderer:
    TITLE_H  = 30
    ROW_H    = 42
    INFO_H   = 22
    BTN_H    = 34
    STRIPE_W = 6
    MARGIN   = 10

    STATUS_COLORS = {
        "connected":    GREEN,
        "provisioning": YELLOW,
        "running":      YELLOW,
        "stopped":      RED,
        "disconnected": RED,
        "error":        RED,
    }
    STATUS_LABELS = {
        "connected":    "CONNECTED",
        "provisioning": "PROVISIONING",
        "running":      "RUNNING",
        "stopped":      "STOPPED",
        "disconnected": "DISCONNECTED",
        "error":        "ERROR",
    }

    def __init__(self):
        self.f_title  = load_font(16, bold=True)
        self.f_label  = load_font(14, bold=True)
        self.f_value  = load_font(14)
        self.f_small  = load_font(12)

        # Button rects as (x, y, w, h)
        btn_y = SCREEN_H - self.BTN_H
        self.btn_sleep   = (0,            btn_y, SCREEN_W // 2, self.BTN_H)
        self.btn_refresh = (SCREEN_W // 2, btn_y, SCREEN_W // 2, self.BTN_H)

    def _color(self, state):
        return self.STATUS_COLORS.get(state, GRAY)

    def _label(self, state):
        return self.STATUS_LABELS.get(state, state.upper())

    def _txt(self, draw, font, text, xy, color=WHITE):
        draw.text(xy, str(text), font=font, fill=color)

    def render(self, status: dict, backlight_on: bool, refreshing: bool) -> Image.Image:
        img  = Image.new("RGB", (SCREEN_W, SCREEN_H), DARK)
        draw = ImageDraw.Draw(img)

        if not backlight_on:
            return img   # black frame

        # ---- Title bar -------------------------------------------------------
        draw.rectangle([0, 0, SCREEN_W, self.TITLE_H], fill=BLUE)
        hostname = status.get("hostname", "CoreMP135")
        self._txt(draw, self.f_title, f"  {hostname}", (0, 6))

        y = self.TITLE_H + 2

        # ---- ThingsBoard row -------------------------------------------------
        tb_state = status.get("tb_state", "…")
        tb_color = self._color(tb_state)
        draw.rectangle([0, y, SCREEN_W, y + self.ROW_H], fill=PANEL)
        draw.rectangle([0, y, self.STRIPE_W, y + self.ROW_H], fill=tb_color)
        x = self.STRIPE_W + self.MARGIN
        self._txt(draw, self.f_label, "ThingsBoard", (x, y + 3))
        self._txt(draw, self.f_value, self._label(tb_state), (x, y + 19), tb_color)
        y += self.ROW_H + 2

        # ---- Tailscale row ---------------------------------------------------
        ts_state = status.get("ts_state", "…")
        ts_color = self._color(ts_state)
        draw.rectangle([0, y, SCREEN_W, y + self.ROW_H], fill=PANEL)
        draw.rectangle([0, y, self.STRIPE_W, y + self.ROW_H], fill=ts_color)
        x = self.STRIPE_W + self.MARGIN
        self._txt(draw, self.f_label, "Tailscale", (x, y + 3))
        ts_txt = self._label(ts_state)
        ts_ip  = status.get("ts_ip", "")
        if ts_ip and ts_ip != "—":
            ts_txt += f"  {ts_ip}"
        self._txt(draw, self.f_value, ts_txt, (x, y + 19), ts_color)
        y += self.ROW_H + 2

        # ---- eth0 row --------------------------------------------------------
        draw.rectangle([0, y, SCREEN_W, y + self.ROW_H], fill=PANEL)
        draw.rectangle([0, y, self.STRIPE_W, y + self.ROW_H], fill=BLUE)
        x = self.STRIPE_W + self.MARGIN
        self._txt(draw, self.f_label, "eth0", (x, y + 3))
        self._txt(draw, self.f_value, status.get("eth0_ip", "—"), (x, y + 19))
        y += self.ROW_H + 2

        # ---- Info strip ------------------------------------------------------
        draw.rectangle([0, y, SCREEN_W, y + self.INFO_H], fill=(25, 25, 25))
        uptime = status.get("uptime", "")
        ref    = status.get("refreshed_at", "")
        self._txt(draw, self.f_small, f" up {uptime}", (0, y + 4), GRAY)
        ref_txt = f"{'refreshing…' if refreshing else ref}"
        # right-align the refresh time
        try:
            tw = self.f_small.getlength(ref_txt)
        except AttributeError:
            tw = len(ref_txt) * 6
        self._txt(draw, self.f_small, ref_txt, (SCREEN_W - tw - 4, y + 4), GRAY)
        y += self.INFO_H

        # ---- Buttons ---------------------------------------------------------
        draw.rectangle([0, y, SCREEN_W, SCREEN_H], fill=PANEL2)
        draw.line([(SCREEN_W // 2, y), (SCREEN_W // 2, SCREEN_H)], fill=GRAY, width=1)
        draw.line([(0, y), (SCREEN_W, y)], fill=GRAY, width=1)

        sleep_lbl   = "Screen OFF" if backlight_on else "Screen ON"
        refresh_lbl = "Refreshing…" if refreshing else "Refresh"

        cy = y + self.BTN_H // 2

        # center the button labels
        for txt, cx in [(sleep_lbl, SCREEN_W // 4), (refresh_lbl, 3 * SCREEN_W // 4)]:
            try:
                tw = self.f_small.getlength(txt)
            except AttributeError:
                tw = len(txt) * 6
            self._txt(draw, self.f_small, txt, (cx - tw // 2, cy - 5), WHITE)

        return img

    def hit_sleep(self, x, y):
        bx, by, bw, bh = self.btn_sleep
        return bx <= x < bx + bw and by <= y < by + bh

    def hit_refresh(self, x, y):
        bx, by, bw, bh = self.btn_refresh
        return bx <= x < bx + bw and by <= y < by + bh

# ---------------------------------------------------------------------------
# Touch input thread
# ---------------------------------------------------------------------------
class TouchReader(threading.Thread):
    def __init__(self, device, callback):
        super().__init__(daemon=True)
        self.device   = device
        self.callback = callback
        self._x = 0
        self._y = 0

    def run(self):
        if not HAS_EVDEV:
            return
        try:
            dev = InputDevice(self.device)
            print(f"[TOUCH] Listening on {self.device}: {dev.name}")
            for event in dev.read_loop():
                if event.type == ecodes.EV_ABS:
                    if event.code == ecodes.ABS_X:
                        self._x = event.value
                    elif event.code == ecodes.ABS_Y:
                        self._y = event.value
                elif event.type == ecodes.EV_KEY:
                    if event.code == ecodes.BTN_TOUCH and event.value == 1:
                        self.callback(self._x, self._y)
        except Exception as e:
            print(f"[TOUCH] Error: {e}")

# ---------------------------------------------------------------------------
# Main application
# ---------------------------------------------------------------------------
class GatewayDisplay:
    def __init__(self):
        self.fb          = Framebuffer(FB_DEVICE)
        self.renderer    = Renderer()
        self.status      = {}
        self._lock       = threading.Lock()
        self._refreshing = False
        self.backlight   = True
        self.last_ref    = 0.0

        set_backlight(True)

        # Start touch listener
        if HAS_EVDEV and os.path.exists(TOUCH_DEVICE):
            TouchReader(TOUCH_DEVICE, self._on_touch).start()
        else:
            print(f"[TOUCH] {TOUCH_DEVICE} not found or evdev missing")

        # Initial refresh
        self._trigger_refresh()

    # -- status ---------------------------------------------------------------

    def _trigger_refresh(self):
        if self._refreshing:
            return
        self._refreshing = True
        threading.Thread(target=self._do_refresh, daemon=True).start()

    def _do_refresh(self):
        ts_state, ts_ip = get_tailscale_status()
        tb_state         = get_tb_status()
        with self._lock:
            self.status = {
                "tb_state":      tb_state,
                "ts_state":      ts_state,
                "ts_ip":         ts_ip or "—",
                "eth0_ip":       get_eth0_ip(),
                "uptime":        get_uptime(),
                "hostname":      socket.gethostname(),
                "refreshed_at":  time.strftime("%H:%M:%S"),
            }
        self._refreshing = False
        self.last_ref    = time.time()

    # -- touch ----------------------------------------------------------------

    def _on_touch(self, x, y):
        if not self.backlight:
            self.backlight = True
            set_backlight(True)
            return
        if self.renderer.hit_sleep(x, y):
            self.backlight = False
            set_backlight(False)
        elif self.renderer.hit_refresh(x, y):
            self._trigger_refresh()

    # -- main loop ------------------------------------------------------------

    def run(self):
        print("[DISPLAY] Running — Ctrl+C to exit")
        try:
            while True:
                if time.time() - self.last_ref > REFRESH_INTERVAL:
                    self._trigger_refresh()

                with self._lock:
                    s = dict(self.status)

                frame = self.renderer.render(s, self.backlight, self._refreshing)
                self.fb.write(frame)
                time.sleep(1)   # 1 FPS is enough for a status screen
        except KeyboardInterrupt:
            self.fb.clear()
            print("\n[DISPLAY] Exited")

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # Quick FB probe
    if not os.path.exists(FB_DEVICE):
        print(f"[ERROR] Framebuffer {FB_DEVICE} not found")
        sys.exit(1)

    GatewayDisplay().run()
