#!/usr/bin/env python3
"""Task 7 - recover an AES key that is only an English word.

The setup: the key is an English word shorter than 16 characters, padded out to
16 bytes with '#'. That is not a 128-bit key in any meaningful sense - the real
search space is the size of a dictionary, about 10^5, not 2^128. A laptop walks
it in under a second.

Against the lab's own numbers (copy them from your handout, Task 7):

    python3 task7_bruteforce.py \\
        --plaintext "This is a top secret." \\
        --ciphertext <hex> \\
        --iv 00000000000000000000000000000000 \\
        --words ../Files/words.txt

With no arguments it builds its own challenge and cracks that, which proves the
code works even if you have not typed the handout values in yet.
"""
import argparse
import os
import random
import sys
import time

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WORDS = os.path.join(HERE, "..", "Files", "words.txt")


def load_words(path, pad_char="#", keylen=16):
    """Every dictionary word short enough to be padded into a key."""
    out = []
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            w = line.strip()
            if w and w.isascii() and len(w) < keylen:
                out.append(w)
    return out


def candidate_keys(word, pad_char, keylen, try_case):
    """The lab pads on the right with '#'. Case is not stated, so try both."""
    forms = {word}
    if try_case:
        forms |= {word.lower(), word.capitalize(), word.upper()}
    for form in forms:
        if len(form) < keylen:
            yield form, (form + pad_char * (keylen - len(form))).encode()


def crack(plaintext, ciphertext, iv, words, pad_char="#", mode="cbc", try_case=True):
    keylen = 16
    target = ciphertext[:16]        # first block is enough to identify the key
    modes = {"cbc": AES.MODE_CBC, "ecb": AES.MODE_ECB, "cfb": AES.MODE_CFB,
             "ofb": AES.MODE_OFB}
    aes_mode = modes[mode]
    padded = pad(plaintext, 16)
    tried = 0
    for word in words:
        for form, key in candidate_keys(word, pad_char, keylen, try_case):
            tried += 1
            if aes_mode == AES.MODE_ECB:
                cipher = AES.new(key, aes_mode)
            elif aes_mode == AES.MODE_CFB:
                cipher = AES.new(key, aes_mode, iv, segment_size=128)
            else:
                cipher = AES.new(key, aes_mode, iv)
            if cipher.encrypt(padded)[:16] == target:
                return form, key, tried
    return None, None, tried


def self_test(words):
    secret = random.choice([w for w in words if 4 <= len(w) <= 10])
    key = (secret + "#" * (16 - len(secret))).encode()
    iv = b"\x00" * 16
    pt = b"This is a top secret."
    ct = AES.new(key, AES.MODE_CBC, iv).encrypt(pad(pt, 16))
    print("self-test: a key was picked from the dictionary at random")
    print(f"  plaintext  : {pt.decode()}")
    print(f"  ciphertext : {ct.hex()}")
    print(f"  IV         : {iv.hex()}")
    print("  cracking...")
    t0 = time.time()
    found, fkey, tried = crack(pt, ct, iv, words)
    dt = time.time() - t0
    print(f"  key found  : {found!r} -> {fkey!r}")
    print(f"  it was     : {secret!r}")
    print(f"  {tried} keys tried in {dt:.2f}s ({tried / max(dt, 1e-9):,.0f} keys/sec)")
    print(f"  RESULT     : {'PASS' if fkey == key else 'FAIL'}")
    return fkey == key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plaintext", default="This is a top secret.")
    ap.add_argument("--ciphertext", help="hex")
    ap.add_argument("--iv", default="0" * 32, help="hex")
    ap.add_argument("--words", default=DEFAULT_WORDS)
    ap.add_argument("--pad-char", default="#")
    ap.add_argument("--mode", default="cbc", choices=["cbc", "ecb", "cfb", "ofb"])
    args = ap.parse_args()

    words = load_words(args.words)
    print(f"dictionary: {len(words)} words shorter than 16 characters")

    if not args.ciphertext:
        print("(no --ciphertext given, running the self-test)\n")
        sys.exit(0 if self_test(words) else 1)

    pt = args.plaintext.encode()
    ct = bytes.fromhex(args.ciphertext.replace(" ", ""))
    iv = bytes.fromhex(args.iv.replace(" ", ""))

    t0 = time.time()
    found, key, tried = crack(pt, ct, iv, words, args.pad_char, args.mode)
    dt = time.time() - t0

    if found:
        print(f"\nKEY FOUND: {found!r}")
        print(f"  as 16 bytes : {key!r}")
        print(f"  as hex      : {key.hex()}")
        print(f"  {tried} keys tried in {dt:.2f}s")
    else:
        print(f"\nno key found after {tried} candidates in {dt:.2f}s")
        print("things to check:")
        print("  - the ciphertext hex is copied exactly (one wrong digit = no match)")
        print("  - the plaintext matches character for character, spaces included")
        print("  - the word is in this dictionary; try --words with the lab's own file")
        sys.exit(1)


if __name__ == "__main__":
    main()
