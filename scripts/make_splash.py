#!/usr/bin/env python3
"""Generate assets/splash.png: the egui-cr splash image — an
anti-aliased circle on a transparent background with a vertical blue
gradient and a white "E" in the middle (the round variant of the
project icon). Stdlib only (zlib/struct PNG writer).

Run:  python3 scripts/make_splash.py
"""

import struct
import zlib

SIZE = 256          # square image, also the splash window size
CX = CY = SIZE / 2
RADIUS = SIZE / 2 - 2

# Vertical gradient (top → bottom), the icon's blue
TOP = (0x62, 0xB0, 0xE8)
BOTTOM = (0x2D, 0x6F, 0xD6)

# "E" bars: x0..x1 / y0..y1 inclusive, in image pixels (128px tall,
# 22px strokes, middle arm slightly shorter — classic glyph look)
E_VERTICAL = (86, 108, 76, 180)
E_TOP = (86, 158, 76, 98)
E_MID = (86, 150, 119, 141)
E_BOTTOM = (86, 158, 158, 180)

SS = 4  # supersampling factor for the anti-aliased edge


def lerp(a, b, t):
    return a + (b - a) * t


def in_rect(x, y, r):
    return r[0] <= x < r[1] and r[2] <= y < r[3]


def render():
    px = bytearray()
    for y in range(SIZE):
        px.append(0)  # filter type 0 (None) per scanline
        for x in range(SIZE):
            # 4x4 supersampled coverage of the circle
            inside = 0
            for sy in range(SS):
                for sx in range(SS):
                    fx = x + (sx + 0.5) / SS - CX
                    fy = y + (sy + 0.5) / SS - CY
                    if fx * fx + fy * fy <= RADIUS * RADIUS:
                        inside += 1
            if inside == 0:
                px += bytes((0, 0, 0, 0))
                continue
            cov = inside / (SS * SS)

            t = y / (SIZE - 1)
            r = lerp(TOP[0], BOTTOM[0], t)
            g = lerp(TOP[1], BOTTOM[1], t)
            b = lerp(TOP[2], BOTTOM[2], t)

            # "E": white wherever any supersample hits a bar
            white = 0
            for sy in range(SS):
                for sx in range(SS):
                    fx = x + (sx + 0.5) / SS
                    fy = y + (sy + 0.5) / SS
                    if (in_rect(fx, fy, E_VERTICAL) or in_rect(fx, fy, E_TOP)
                            or in_rect(fx, fy, E_MID)
                            or in_rect(fx, fy, E_BOTTOM)):
                        white += 1
            if white:
                wr = white / (SS * SS)
                r = lerp(r, 255, wr)
                g = lerp(g, 255, wr)
                b = lerp(b, 255, wr)

            px += bytes((round(r), round(g), round(b),
                         round(255 * cov)))
    return bytes(px)


def write_png(path, data):
    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body)))

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # RGBA8
    raw = b"".join([b"\x89PNG\r\n\x1a\n",
                    chunk(b"IHDR", ihdr),
                    chunk(b"IDAT", zlib.compress(data, 9)),
                    chunk(b"IEND", b"")])
    with open(path, "wb") as f:
        f.write(raw)


if __name__ == "__main__":
    out = "assets/splash.png"
    write_png(out, render())
    print(f"wrote {out} ({SIZE}x{SIZE} RGBA)")
