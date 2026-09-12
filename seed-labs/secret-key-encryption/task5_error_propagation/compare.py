#!/usr/bin/env python3
"""Report exactly which bytes and which 16-byte blocks came back wrong."""
import sys

orig = open(sys.argv[1], "rb").read()
bad = open(sys.argv[2], "rb").read()
label = sys.argv[3]

n = min(len(orig), len(bad))
diff = [i for i in range(n) if orig[i] != bad[i]]
blocks = sorted({i // 16 for i in diff})
if not diff:
    print(f"  {label:14} no corruption at all\n")
else:
    bits = sum(bin(orig[i] ^ bad[i]).count("1") for i in diff)
    span = f"bytes {diff[0]}..{diff[-1]}"
    print(f"  {label:14} {len(diff):5} bytes wrong ({bits} bits), {span}, "
          f"blocks {blocks if len(blocks) <= 6 else str(blocks[:6]) + '...'}\n")
