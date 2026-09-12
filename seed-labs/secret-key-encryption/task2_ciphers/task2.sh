#!/bin/bash
# Task 2 - encryption with different ciphers and modes.
#
# openssl enc -<cipher> -e -in <plain> -out <cipher> -K <hexkey> -iv <hexiv>
# -K and -iv take raw hex, so no password-based key derivation is involved:
# the key really is the 16 bytes you type.
set -u
cd "$(dirname "$0")"
IN=../Files/plain.txt
OUT=../results/task2
mkdir -p "$OUT"

KEY=00112233445566778899aabbccddeeff          # 128-bit key
IV=0102030405060708090a0b0c0d0e0f10           # 128-bit IV (64-bit for Blowfish)

echo "input: $(wc -c < $IN) bytes"
echo

run () {
  local name=$1 iv=$2 extra=${3:-}
  # shellcheck disable=SC2086
  openssl enc -"$name" -e -in "$IN" -out "$OUT/plain.$name" -K "$KEY" ${iv:+-iv $iv} $extra 2>/dev/null
  local size
  size=$(wc -c < "$OUT/plain.$name")
  printf '%-14s ciphertext %4s bytes   %s\n' "$name" "$size" \
    "$(od -An -tx1 -v "$OUT/plain.$name" | tr -d ' \n' | cut -c1-48)..."
  # Decrypt again to prove the round trip.
  # shellcheck disable=SC2086
  openssl enc -"$name" -d -in "$OUT/plain.$name" -out "$OUT/back.$name" -K "$KEY" ${iv:+-iv $iv} $extra 2>/dev/null
  cmp -s "$IN" "$OUT/back.$name" && echo "               round trip OK" || echo "               ROUND TRIP FAILED"
}

echo "=== three ciphers, as the task asks ==="
run aes-128-cbc "$IV"
run aes-128-cfb "$IV"
# Blowfish moved to the legacy provider in OpenSSL 3.x; it is not built in by
# default any more. On the SEED 20.04 VM (OpenSSL 1.1.1) drop the -provider flags.
run bf-cbc "${IV:0:16}" "-provider legacy -provider default"

echo
echo "=== a few more modes for comparison ==="
run aes-128-ecb ""
run aes-128-ofb "$IV"
run aes-128-ctr "$IV"
run aes-256-cbc "$IV$IV"   # note: -K must be 32 bytes of hex for a 256-bit key

echo
echo "full list of ciphers this openssl supports: openssl enc -ciphers"
