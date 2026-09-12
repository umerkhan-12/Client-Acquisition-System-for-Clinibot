#!/bin/bash
# Task 4 - padding.
#
# PKCS#5/#7: append N bytes each holding the value N, where N is whatever it
# takes to fill the last block. If the data already fills a block exactly, a
# WHOLE extra block of 0x10 is added - otherwise decryption could not tell
# padding from data.
set -eu
cd "$(dirname "$0")"
OUT=../results/task4
mkdir -p "$OUT"
KEY=00112233445566778899aabbccddeeff
IV=0102030405060708090a0b0c0d0e0f10

echo "=== which modes pad at all? ==="
printf 'Input bytes | '
for m in aes-128-ecb aes-128-cbc aes-128-cfb aes-128-ofb; do printf '%-12s ' "$m"; done; echo
for n in 5 10 16; do
  head -c $n /dev/zero | tr '\0' 'A' > "$OUT/in$n.txt"
  printf '%11s | ' "$n"
  for m in aes-128-ecb aes-128-cbc aes-128-cfb aes-128-ofb; do
    if [ "$m" = aes-128-ecb ]; then
      openssl enc -$m -e -in "$OUT/in$n.txt" -out "$OUT/in$n.$m" -K $KEY
    else
      openssl enc -$m -e -in "$OUT/in$n.txt" -out "$OUT/in$n.$m" -K $KEY -iv $IV
    fi
    printf '%-12s ' "$(wc -c < "$OUT/in$n.$m")"
  done
  echo
done

echo
echo "=== what the padding actually contains (CBC, -nopad on decrypt; od replaces hexdump -C) ==="
for n in 5 10 16; do
  echo "--- plaintext was $n bytes of 'A' ---"
  openssl enc -aes-128-cbc -d -nopad -in "$OUT/in$n.aes-128-cbc" -K $KEY -iv $IV | od -A x -t x1z -v
done
