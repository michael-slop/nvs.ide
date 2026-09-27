"""Check a window screenshot is a real frame, not a blank or cleared one.

    python3 tests/screenshot_check.py shot.png [min_colours]

Reads the PNG nvs-ide --screenshot writes (8-bit RGBA, not interlaced) with the standard
library only, and fails unless it has at least `min_colours` distinct colours (default
16): a cleared surface has one, the workbench with text has hundreds. CI runs it after the
offscreen screenshot on Linux, where no one looks at the picture.
"""

import struct
import sys
import zlib


def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, header = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in (2, 6) or interlace:
        raise SystemExit(f"{path}: expected 8-bit RGB or RGBA, not interlaced; got depth {depth} colour type {colour}")
    bpp = 4 if colour == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        base = y * (stride + 1)
        kind, line = raw[base], bytearray(raw[base + 1:base + 1 + stride])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, bpp, rows


def main():
    path = sys.argv[1]
    minimum = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    width, height, bpp, rows = decode(path)
    colours = set()
    for row in rows:
        for i in range(0, len(row), bpp):
            colours.add(row[i:i + 3])
    print(f"{path}: {width}x{height}, {len(colours)} distinct colours")
    if len(colours) < minimum:
        raise SystemExit(f"FAIL: fewer than {minimum} colours; the frame is blank")


if __name__ == "__main__":
    main()
