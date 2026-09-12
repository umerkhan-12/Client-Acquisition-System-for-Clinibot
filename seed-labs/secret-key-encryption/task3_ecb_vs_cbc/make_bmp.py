#!/usr/bin/env python3
"""Draw a 24-bit BMP with large flat regions, so ECB leakage is obvious.

The SEED lab ships pic_original.bmp. This generates an equivalent picture so
the task can be run anywhere. Use the lab's own file if you have it - the
commands are identical.
"""
import math
import os
import struct

W, H = 480, 320
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Files", "pic_original.bmp")

WHITE, BLACK, BLUE = (255, 255, 255), (20, 20, 20), (200, 90, 30)  # stored BGR


def main():
    px = [[WHITE for _ in range(W)] for _ in range(H)]
    cx, cy, r = W // 2, H // 2, 120

    for y in range(H):
        for x in range(W):
            d = math.hypot(x - cx, y - cy)
            if d <= r:
                px[y][x] = BLUE
            if math.hypot(x - (cx - 45), y - (cy - 35)) <= 18:
                px[y][x] = BLACK          # left eye
            if math.hypot(x - (cx + 45), y - (cy - 35)) <= 18:
                px[y][x] = BLACK          # right eye
            if 60 <= d <= 78 and y > cy + 12:
                px[y][x] = BLACK          # mouth

    # A solid bar: one plaintext block repeated hundreds of times.
    for y in range(20, 60):
        for x in range(40, W - 40):
            px[y][x] = BLACK

    row_pad = (-W * 3) % 4
    body = bytearray()
    for y in range(H - 1, -1, -1):                  # BMP rows run bottom-up
        for x in range(W):
            body += bytes(px[y][x])
        body += b"\x00" * row_pad

    header = struct.pack("<2sIHHI", b"BM", 54 + len(body), 0, 0, 54)
    dib = struct.pack("<IiiHHIIiiII", 40, W, H, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    with open(OUT, "wb") as fh:
        fh.write(header + dib + bytes(body))
    print(f"wrote {OUT}: {W}x{H}, {54 + len(body)} bytes, 54-byte header")


if __name__ == "__main__":
    main()
