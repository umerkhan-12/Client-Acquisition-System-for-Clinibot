#!/bin/bash
# Task 6.1 - does the IV matter?
set -eu
cd "$(dirname "$0")"
OUT=../results/task6
mkdir -p "$OUT"
IN=../Files/plain.txt
KEY=00112233445566778899aabbccddeeff
IV1=0102030405060708090a0b0c0d0e0f10
IV2=0102030405060708090a0b0c0d0e0f11   # differs in the last bit only

enc () { openssl enc -aes-128-cbc -e -in "$IN" -out "$2" -K $KEY -iv "$1"; }

enc $IV1 "$OUT/run1.bin"
enc $IV1 "$OUT/run2.bin"
enc $IV2 "$OUT/run3.bin"

echo "same key, same IV   (run1 vs run2): $(cmp -s "$OUT/run1.bin" "$OUT/run2.bin" && echo IDENTICAL || echo different)"
echo "same key, IV+1 bit  (run1 vs run3): $(cmp -s "$OUT/run1.bin" "$OUT/run3.bin" && echo IDENTICAL || echo different)"
echo
for f in run1 run2 run3; do
  printf '%-5s %s\n' "$f" "$(od -An -tx1 -v "$OUT/$f.bin" | tr -d ' \n' | cut -c1-64)"
done
echo
echo "Reusing an IV makes encryption deterministic: an eavesdropper learns"
echo "when you sent the same message twice, without breaking AES at all."
