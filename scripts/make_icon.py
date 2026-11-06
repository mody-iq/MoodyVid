#!/usr/bin/env python3
"""Draws the MoodyVid app icon.

The build runs on a stock macOS runner where Pillow is not guaranteed, so this
writes the PNG by hand: a rounded teal tile with a white play mark. It is pure
stdlib (zlib + struct) and deterministic, so the icon never drifts between runs.

Usage: python3 scripts/make_icon.py <out.png> [size]
"""
import struct
import sys
import zlib


def blend(dst, src, alpha):
    return tuple(round(d + (s - d) * alpha) for d, s in zip(dst, src))


def rounded_alpha(x, y, size, radius):
    """1 inside the rounded square, 0 outside, with a one-pixel soft edge."""
    cx = min(max(x, radius), size - 1 - radius)
    cy = min(max(y, radius), size - 1 - radius)
    dx, dy = x - cx, y - cy
    dist = (dx * dx + dy * dy) ** 0.5
    if dist <= radius - 1:
        return 1.0
    if dist >= radius:
        return 0.0
    return radius - dist


def triangle_alpha(x, y, size):
    """Coverage of a right-pointing play triangle centred on the tile."""
    # Triangle corners, scaled from the 1024 design so any size works.
    s = size / 1024.0
    apex = (700 * s, 512 * s)
    top = (380 * s, 300 * s)
    bottom = (380 * s, 724 * s)

    def edge(px, py, ax, ay, bx, by):
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax)

    d1 = edge(x, y, top[0], top[1], apex[0], apex[1])
    d2 = edge(x, y, apex[0], apex[1], bottom[0], bottom[1])
    d3 = edge(x, y, bottom[0], bottom[1], top[0], top[1])
    inside = (d1 >= 0 and d2 >= 0 and d3 >= 0) or (d1 <= 0 and d2 <= 0 and d3 <= 0)
    if not inside:
        return 0.0
    # Distance to the nearest edge, for a soft border.
    def dist_to(ax, ay, bx, by):
        vx, vy = bx - ax, by - ay
        wx, wy = x - ax, y - ay
        t = max(0.0, min(1.0, (wx * vx + wy * vy) / (vx * vx + vy * vy)))
        px, py = ax + t * vx, ay + t * vy
        return ((x - px) ** 2 + (y - py) ** 2) ** 0.5

    d = min(dist_to(*top, *apex), dist_to(*apex, *bottom), dist_to(*bottom, *top))
    return 1.0 if d >= 1.0 else d


def render(size):
    radius = size * 0.225
    top_color = (18, 172, 186)
    bottom_color = (8, 116, 132)
    rows = []
    for y in range(size):
        t = y / max(1, size - 1)
        base = blend(top_color, bottom_color, t)
        row = bytearray()
        row.append(0)  # PNG filter type: none
        for x in range(size):
            r, g, b = base
            a = rounded_alpha(x, y, size, radius)
            cover = triangle_alpha(x, y, size)
            if cover > 0:
                r, g, b = blend((r, g, b), (255, 255, 255), cover)
            row += bytes((r, g, b, round(a * 255)))
        rows.append(bytes(row))
    return b"".join(rows)


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path, size):
    raw = render(size)
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    path = argv[1]
    size = int(argv[2]) if len(argv) > 2 else 1024
    write_png(path, size)
    print(f"icon written: {path} ({size}x{size})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
