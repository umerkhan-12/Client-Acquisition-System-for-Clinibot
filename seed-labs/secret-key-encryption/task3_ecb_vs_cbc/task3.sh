#!/bin/bash
# Task 3 - ECB vs CBC on a picture.
#
# The trick: encrypt the whole .bmp, then paste the original 54-byte header
# back on top, so an image viewer still recognises the file and renders the
# encrypted bytes as pixels.
set -eu
cd "$(dirname "$0")"
# Any .bmp may be given; defaults to the generated one.
#   ./task3.sh ../Files/official/pic_original.bmp
PIC=${1:-../Files/pic_original.bmp}
OUT=../results/task3
[ "$PIC" = "../Files/pic_original.bmp" ] || OUT=../results/task3_official
mkdir -p "$OUT"
KEY=00112233445566778899aabbccddeeff
IV=0102030405060708090a0b0c0d0e0f10

[ -f "$PIC" ] || python3 make_bmp.py
echo "picture: $PIC -> $OUT"

for mode in ecb cbc; do
  if [ "$mode" = ecb ]; then
    openssl enc -aes-128-ecb -e -in "$PIC" -out "$OUT/body.$mode" -K $KEY
  else
    openssl enc -aes-128-cbc -e -in "$PIC" -out "$OUT/body.$mode" -K $KEY -iv $IV
  fi
  head -c 54 "$PIC"                  >  "$OUT/pic_$mode.bmp"
  tail -c +55 "$OUT/body.$mode"      >> "$OUT/pic_$mode.bmp"
  printf '%-4s -> %s (%s bytes)\n' "$mode" "$OUT/pic_$mode.bmp" "$(wc -c < "$OUT/pic_$mode.bmp")"
done

echo
echo "How much structure survives? Count how often the most common 16-byte"
echo "block repeats - that repetition IS the leak."
python3 - "$OUT" <<'PY'
import collections, os
out = os.path.join(os.path.dirname(os.path.abspath(__file__)) if '__file__' in dir() else '.', '')
import sys
out = sys.argv[1] if len(sys.argv) > 1 else "../results/task3"
for name in (f"{out}/body.ecb", f"{out}/body.cbc"):
    data = open(name, 'rb').read()[54:]
    blocks = [data[i:i+16] for i in range(0, len(data) - 15, 16)]
    c = collections.Counter(blocks)
    top, n = c.most_common(1)[0]
    print(f"{os.path.basename(name):10} {len(blocks):6} blocks, "
          f"{len(c):6} distinct, most common block repeats {n:5} times")
PY
