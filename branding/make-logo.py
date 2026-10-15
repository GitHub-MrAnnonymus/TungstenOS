#!/usr/bin/env python3
"""Generates the TungstenOS logo files from one geometry.

The mark: an isometric body-centred cubic cell (tungsten's crystal lattice). Four of its
real edges trace a W - down the left edge, up to the near corner, down, up the right
edge - whose middle peak lands on the body-centred atom. The W is drawn as a glowing
filament, the rest of the cell as a metal frame.

Writes into root_files/ (run from anywhere, then commit the results):
  usr/share/pixmaps/tungstenos.svg            full mark (coiled filament, atoms, glow)
  usr/share/pixmaps/tungstenos-small.svg      small sizes (straight filament, no blur)
  usr/share/icons/hicolor/scalable/apps/tungstenos.svg
  usr/share/plymouth/themes/tungsten/{frame,cold,hot,glow}.svg   boot splash layers
  usr/share/tungsten/fastfetch-logo.txt       Braille version for fastfetch
"""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "root_files"
R = 100.0
S = math.sqrt(3) / 2
P = {"T": (0, -R), "UR": (S * R, -R / 2), "LR": (S * R, R / 2), "B": (0, R),
     "LL": (-S * R, R / 2), "UL": (-S * R, -R / 2), "C": (0, 0)}
W = [P[k] for k in ("UL", "LL", "C", "LR", "UR")]
FRAME = [("UL", "T"), ("T", "UR"), ("LL", "B"), ("B", "LR"), ("C", "T")]
CORNERS = ("T", "UR", "LR", "B", "LL", "UL")

METAL, METAL_DARK, GLOW, HOT, EMBER = "#8f96a3", "#2b2f36", "#ffb46b", "#fff3df", "#5a1f0a"


def f(n):
    return f"{n:.2f}"


def line(points):
    return "".join(("L" if i else "M") + f(x) + " " + f(y) for i, (x, y) in enumerate(points))


def coil(points, amp=5.5, waves=9, steps=140):
    """The W as a coiled filament: a sine offset across each edge, flat at the corners."""
    out = []
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        nx, ny = -dy / length, dx / length
        for j in range(steps + 1):
            t = j / steps
            env = min(1, t * 6, (1 - t) * 6)
            o = math.sin(t * waves * 2 * math.pi) * amp * env
            out.append((x1 + dx * t + nx * o, y1 + dy * t + ny * o))
    return line(out)


def svg(body, pad=22):
    v = R + pad
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{f(-v)} {f(-v)} {f(2 * v)} {f(2 * v)}" '
            f'width="512" height="512">\n<defs><filter id="blur" x="-50%" y="-50%" width="200%" height="200%">'
            f'<feGaussianBlur stdDeviation="9"/></filter></defs>\n{body}</svg>\n')


def frame_paths(color, width, opacity=1.0):
    return "".join(f'<path d="{line([P[a], P[b]])}" stroke="{color}" stroke-width="{width}" '
                   f'stroke-linecap="round" fill="none" opacity="{opacity}"/>\n' for a, b in FRAME)


def atoms(color, r=5.5):
    return "".join(f'<circle cx="{f(P[k][0])}" cy="{f(P[k][1])}" r="{r}" fill="{color}"/>\n' for k in CORNERS)


def glow_path(color, width, opacity):
    return (f'<path d="{line(W)}" stroke="{color}" stroke-width="{width}" stroke-linejoin="round" '
            f'stroke-linecap="round" fill="none" opacity="{opacity}" filter="url(#blur)"/>\n')


def filament(d, color, width):
    return (f'<path d="{d}" stroke="{color}" stroke-width="{width}" stroke-linejoin="round" '
            f'stroke-linecap="round" fill="none"/>\n')


def centre(color, halo=True):
    s = f'<circle cx="0" cy="0" r="22" fill="{GLOW}" opacity=".35" filter="url(#blur)"/>\n' if halo else ""
    return s + f'<circle cx="0" cy="0" r="9" fill="{color}"/>\n'


def write(rel, text):
    p = ROOT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    print("wrote", p.relative_to(ROOT.parent))


full = svg(frame_paths(METAL, 2.2, 0.9) + glow_path(GLOW, 30, 0.35)
           + filament(coil(W), GLOW, 3.7) + atoms(METAL) + centre(HOT))
small = svg(frame_paths(METAL, 6) + filament(line(W), GLOW, 13)
            + atoms(METAL, 8) + centre(HOT, halo=False), pad=14)
write("usr/share/pixmaps/tungstenos.svg", full)
write("usr/share/icons/hicolor/scalable/apps/tungstenos.svg", full)
write("usr/share/pixmaps/tungstenos-small.svg", small)

# Plymouth: layers stacked by the script; the hot filament and glow fade in with progress.
T = "usr/share/plymouth/themes/tungsten/"
write(T + "frame.svg", svg(frame_paths(METAL_DARK, 2.2) + atoms(METAL_DARK)))
write(T + "cold.svg", svg(filament(coil(W), EMBER, 3.7) + centre(EMBER, halo=False)))
write(T + "hot.svg", svg(filament(coil(W), GLOW, 3.7) + centre(HOT, halo=False)))
write(T + "glow.svg", svg(glow_path(GLOW, 30, 0.55)
                          + '<circle cx="0" cy="0" r="22" fill="#ffb46b" opacity=".5" filter="url(#blur)"/>\n'))


# fastfetch: Braille (2x4 dots per character), $1 frame grey, $2 filament orange.
def braille():
    cols, rows = 30, 15
    wdots, hdots = cols * 2, rows * 4
    scale = (hdots / 2 - 2) / R
    cx, cy = wdots / 2, hdots / 2
    grid = [[0] * wdots for _ in range(hdots)]
    kind = [[0] * wdots for _ in range(hdots)]

    def plot(x, y, k):
        xi, yi = int(round(cx + x * scale)), int(round(cy + y * scale))
        if 0 <= xi < wdots and 0 <= yi < hdots:
            grid[yi][xi] = 1
            kind[yi][xi] = max(kind[yi][xi], k)

    def seg(a, b, k, thick=0):
        n = 200
        for i in range(n + 1):
            t = i / n
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            for ox in range(-thick, thick + 1):
                plot(x + ox / scale, y, k)

    for a, b in FRAME:
        seg(P[a], P[b], 1)
    for a, b in zip(W, W[1:]):
        seg(a, b, 2, thick=1)
    bits = [(0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08), (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80)]
    out = []
    for r in range(rows):
        s, cur = "", None
        for c in range(cols):
            code, k = 0, 0
            for dx, dy, bit in bits:
                y, x = r * 4 + dy, c * 2 + dx
                if grid[y][x]:
                    code |= bit
                    k = max(k, kind[y][x])
            want = "$2" if k == 2 else "$1"
            if code and want != cur:
                s += want
                cur = want
            s += chr(0x2800 + code) if code else " "
        out.append(s.rstrip())
    return "\n".join(out) + "\n"


write("usr/share/tungsten/fastfetch-logo.txt", braille())
