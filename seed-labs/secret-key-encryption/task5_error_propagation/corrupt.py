#!/usr/bin/env python3
"""Flip one bit of one byte in a file - the scripted equivalent of editing it
in ghex/bless, which is what the lab asks you to do by hand."""
import sys

src, dst, offset, mask = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4], 0)
data = bytearray(open(src, "rb").read())
before = data[offset]
data[offset] ^= mask
open(dst, "wb").write(bytes(data))
print(f"  byte {offset}: 0x{before:02x} -> 0x{data[offset]:02x} (flipped mask 0x{mask:02x})")
