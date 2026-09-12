#!/bin/bash
# Task 5 - corrupted ciphertext: how far does one flipped bit spread?
set -eu
cd "$(dirname "$0")"
OUT=../results/task5
mkdir -p "$OUT"
IN=../Files/long.txt
KEY=00112233445566778899aabbccddeeff
IV=0102030405060708090a0b0c0d0e0f10

echo "plaintext: $(wc -c < $IN) bytes"
echo "corrupting one bit of byte 55 (offset 54, inside block 4) of each ciphertext"
echo

for m in aes-128-ecb aes-128-cbc aes-128-cfb aes-128-ofb; do
  if [ "$m" = aes-128-ecb ]; then
    openssl enc -$m -e -in $IN -out "$OUT/c.$m" -K $KEY
  else
    openssl enc -$m -e -in $IN -out "$OUT/c.$m" -K $KEY -iv $IV
  fi
  python3 ./corrupt.py "$OUT/c.$m" "$OUT/c.$m.bad" 54 0x08
  if [ "$m" = aes-128-ecb ]; then
    openssl enc -$m -d -nopad -in "$OUT/c.$m.bad" -out "$OUT/p.$m.bad" -K $KEY
  else
    openssl enc -$m -d -nopad -in "$OUT/c.$m.bad" -out "$OUT/p.$m.bad" -K $KEY -iv $IV
  fi
  python3 ./compare.py $IN "$OUT/p.$m.bad" "$m"
done
