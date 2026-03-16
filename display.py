#!/usr/bin/env python3
"""
CoreMP135 — IoT Gateway Status Display
Diagnostic screen on the built-in 320×240 IPS LCD (/dev/fb1).

Layout:
  ┌─────────────────────────────────┐
  │   CoreMP135 — IoT Gateway       │  ← title bar (blue)
  ├─────────────────────────────────┤
  │ ThingsBoard   CONNECTED         │  ← green/yellow/red indicator
  ├─────────────────────────────────┤
  │ Tailscale     CONNECTED  IP     │
  ├─────────────────────────────────┤
  │ eth0          192.168.x.x       │
  ├──────────────────┬──────────────┤
  │ hostname  uptime │ last refresh │
  ├──────────────────┴──────────────┤
  │  [  Screen OFF  ] [  Refresh  ] │  ← touch buttons
  └─────────────────────────────────┘

Touch:
  - Bottom-left  : toggle screen backlight
  - Bottom-right : force immediate refresh
  - Any touch when screen is off: wake up
"""

import os
import sys
import json
import time
import socket
import threading
import subprocess

# ---------------------------------------------------------------------------
# SDL framebuffer config — must be set BEFORE importing pygame
# ---------------------------------------------------------------------------
os.environ.setdefault("SDL_VIDEODRIVER",  "fbcon")
os.environ.setdefault("SDL_FBDEV",        "/dev/fb1")
os.environ.setdefault("SDL_AUDIODRIVER",  "dummy")
os.environ.setdefault("SDL_NOMOUSE",      "1")

try:
    import pygame
except ImportError:
    print("pygame not found. Install with: pip3 install pygame --break-system-packages")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCREEN_W, SCREEN_H = 320, 240
REFRESH_INTERVAL   = 15   # seconds between automatic refreshes
FPS                = 10   # display frames per second

# Colours
BLACK  = (  0,   0,   0)
WHITE  = (255, 255, 255)
GREEN  = (  0, 200,  80)
RED    = (220,  50,  50)
YELLOW = (255, 190,   0)
BLUE   = ( 30, 120, 255)
GRAY   = ( 80,  80,  80)
DARK   = ( 18,  18,  18)
PANEL  = ( 35,  35,  35)

# ---------------------------------------------------------------------------
# Backlight helpers
# ---------------------------------------------------------------------------
def _find_backlight_path():
    import glob
    candidates = glob.glob("/sys/class/backlight/*/brightness")
    return candidates[0] if candidates else None

BACKLIGHT_PATH = _find_backlight_path()

def set_backlight(on: bool):
    if not BACKLIGHT_PATH:
        return
    try:
        # Read max_brightness to avoid hardcoding
        max_path = BACKLIGHT_PATH.replace("brightness", "max_brightness")
        max_val  = "100"
        if os.path.exists(max_path):
            with open(max_path) as f:
                max_val = f.read().strip()
        with open(BACKLIGHT_PATH, "w") as f:
            f.write(max_val if on else "0")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Status collectors
# ---------------------------------------------------------------------------
def _run(cmd, timeout=4):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception:
        return -1, "", ""

def get_tailscale_status():
    """Returns (state_str, ip_str)."""
    rc, out, _ = _run(["tailscale", "status", "--json"])
    if rc != 0:
        return "error", None
    try:
        data  = json.loads(out)
        state = data.get("BackendState", "")
        if state == "Running":
            _, ip, _ = _run(["tailscale", "ip", "-4"])
            return "connected", ip.strip()
        if state in ("NeedsLogin", "NoState"):
            return "disconnected", None
        return state.lower(), None
    except Exception:
        return "error", None

def get_tb_status():
    """Returns state_str: connected | provisioning | running | stopped | error."""
    rc, out, _ = _run(["docker", "inspect", "--format", "{{.State.Status}}", "tb-gateway"])
    if rc != 0 or out.strip() != "running":
        return "stopped"
    # Scan recent logs (stderr for TB gateway)
    _, out_log, err_log = _run(["docker", "logs", "--tail", "60", "tb-gateway"], timeout=6)
    logs = (out_log + err_log).lower()
    if any(k in logs for k in ("connected to thingsboard", "provisioning was successful",
                                "gateway connected", "[connected]")):
        return "connected"
    if any(k in logs for k in ("provision", "registering")):
        return "provisioning"
    if any(k in logs for k in ("error", "exception", "refused", "timeout")):
        return "error"
    return "running"

def get_eth0_ip():
    rc, out, _ = _run(["ip", "-4", "addr", "show", "eth0"])
    for line in out.splitlines():
        if "inet " in line and "169.254" not in line:
            return line.strip().split()[1].split("/")[0]
    return "unknown"

def get_uptime():
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
        d = int(secs // 86400)
        h = int((secs % 86400) // 3600)
        m = int((secs % 3600) // 60)
        return f"{d}d {h}h {m}m" if d else f"{h}h {m}m"
    except Exception:
        return "?"

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
class GatewayDisplay:

    # -- layout constants --
    TITLE_H  = 26
    ROW_H    = 38
    BTN_H    = 36
    MARGIN   = 10
    STRIPE_W = 5

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
        "provisioning": "PROVISIONING…",
        "running":      "RUNNING",
        "stopped":      "STOPPED",
        "disconnected": "DISCONNECTED",
        "error":        "ERROR",
    }

    def __init__(self):
        pygame.init()
        self.screen  = pygame.display.set_mode((SCREEN_W, SCREEN_H))
        pygame.mouse.set_visible(False)

        # Fonts (monospace works well on framebuffer without font rendering issues)
        self.f_title = pygame.font.SysFont("monospace", 13, bold=True)
        self.f_label = pygame.font.SysFont("monospace", 12, bold=True)
        self.f_value = pygame.font.SysFont("monospace", 12)
        self.f_small = pygame.font.SysFont("monospace", 10)

        # Touch button rects (bottom strip)
        btn_y = SCREEN_H - self.BTN_H
        self.btn_sleep   = pygame.Rect(0,         btn_y, SCREEN_W // 2, self.BTN_H)
        self.btn_refresh = pygame.Rect(SCREEN_W // 2, btn_y, SCREEN_W // 2, self.BTN_H)

        # State
        self.backlight_on  = True
        self.last_refresh  = 0.0
        self.status        = {}
        self._lock         = threading.Lock()
        self._refreshing   = False

        set_backlight(True)
        self._trigger_refresh()

    # -- status update (runs in background thread) --

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
        self._refreshing   = False
        self.last_refresh  = time.time()

    # -- drawing helpers --

    def _color(self, state):
        return self.STATUS_COLORS.get(state, GRAY)

    def _label(self, state):
        return self.STATUS_LABELS.get(state, state.upper())

    def _text(self, font, text, color, pos):
        surf = font.render(str(text), True, color)
        self.screen.blit(surf, pos)
        return surf.get_height()

    def _draw_row(self, y, label, state, extra=""):
        color = self._color(state)
        pygame.draw.rect(self.screen, PANEL, (0, y, SCREEN_W, self.ROW_H))
        pygame.draw.rect(self.screen, color, (0, y, self.STRIPE_W, self.ROW_H))
        x = self.STRIPE_W + self.MARGIN
        self._text(self.f_label, label, WHITE,       (x, y + 4))
        status_txt = self._label(state)
        if extra:
            status_txt += f"  {extra}"
        self._text(self.f_value, status_txt, color, (x, y + 20))

    # -- main draw --

    def draw(self):
        with self._lock:
            s = dict(self.status)

        if not self.backlight_on:
            self.screen.fill(BLACK)
            pygame.display.flip()
            return

        self.screen.fill(DARK)

        # Title bar
        pygame.draw.rect(self.screen, BLUE, (0, 0, SCREEN_W, self.TITLE_H))
        hostname = s.get("hostname", "CoreMP135")
        self._text(self.f_title, f"  {hostname}", WHITE, (0, 6))

        # Content rows
        y = self.TITLE_H + 2
        self._draw_row(y, "ThingsBoard",
                       s.get("tb_state", "…"))
        y += self.ROW_H + 2

        self._draw_row(y, "Tailscale",
                       s.get("ts_state", "…"),
                       s.get("ts_ip", ""))
        y += self.ROW_H + 2

        # eth0 row
        pygame.draw.rect(self.screen, PANEL, (0, y, SCREEN_W, self.ROW_H))
        pygame.draw.rect(self.screen, BLUE,  (0, y, self.STRIPE_W, self.ROW_H))
        x = self.STRIPE_W + self.MARGIN
        self._text(self.f_label, "eth0", WHITE, (x, y + 4))
        self._text(self.f_value, s.get("eth0_ip", "—"), WHITE, (x, y + 20))

        # Uptime + refresh time (right side of eth0 row)
        up    = s.get("uptime", "")
        ref   = s.get("refreshed_at", "")
        self._text(self.f_small, f"up {up}", GRAY,  (SCREEN_W - 85, y + 6))
        self._text(self.f_small, ref,        GRAY,  (SCREEN_W - 85, y + 20))
        y += self.ROW_H + 2

        # Buttons strip
        btn_y = SCREEN_H - self.BTN_H
        pygame.draw.rect(self.screen, (28, 28, 28), (0,             btn_y, SCREEN_W // 2, self.BTN_H))
        pygame.draw.rect(self.screen, (28, 28, 28), (SCREEN_W // 2, btn_y, SCREEN_W // 2, self.BTN_H))
        pygame.draw.line(self.screen, GRAY, (SCREEN_W // 2, btn_y), (SCREEN_W // 2, SCREEN_H), 1)
        pygame.draw.line(self.screen, GRAY, (0, btn_y), (SCREEN_W, btn_y), 1)

        sleep_lbl = "Screen OFF" if self.backlight_on else "Screen ON"
        b1 = self.f_small.render(sleep_lbl, True, WHITE)
        b2 = self.f_small.render("Refresh" + (" …" if self._refreshing else ""), True, WHITE)
        cy = btn_y + self.BTN_H // 2 - b1.get_height() // 2
        self.screen.blit(b1, (SCREEN_W // 4 - b1.get_width() // 2, cy))
        self.screen.blit(b2, (3 * SCREEN_W // 4 - b2.get_width() // 2, cy))

        pygame.display.flip()

    # -- input --

    def handle_touch(self, x, y):
        if not self.backlight_on:
            self.backlight_on = True
            set_backlight(True)
            return
        if self.btn_sleep.collidepoint(x, y):
            self.backlight_on = False
            set_backlight(False)
        elif self.btn_refresh.collidepoint(x, y):
            self._trigger_refresh()

    # -- main loop --

    def run(self):
        clock = pygame.time.Clock()
        while True:
            # Auto-refresh
            if time.time() - self.last_refresh > REFRESH_INTERVAL:
                self._trigger_refresh()

            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    return
                if event.type in (pygame.MOUSEBUTTONDOWN, pygame.FINGERDOWN):
                    pos = (event.x, event.y) if event.type == pygame.FINGERDOWN \
                          else event.pos
                    self.handle_touch(*pos)
                if event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                    return

            self.draw()
            clock.tick(FPS)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    try:
        display = GatewayDisplay()
        display.run()
    finally:
        pygame.quit()
