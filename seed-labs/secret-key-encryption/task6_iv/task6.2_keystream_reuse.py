#!/usr/bin/env python3
"""Task 6.2 - the same IV twice, against a stream mode (OFB/CFB/CTR).

These modes turn the block cipher into a keystream generator and XOR that
keystream over the plaintext:

    C = P XOR KS(key, IV)

The keystream depends only on the key and the IV. Reuse both and two messages
are enciphered with the *same* keystream, so:

    C1 XOR C2 = P1 XOR P2

Know P1 and both ciphertexts, and P2 falls out with no key and no AES:

    P2 = C1 XOR P1 XOR C2

Usage with the numbers from your lab handout (Task 6.2):

    python3 task6.2_keystream_reuse.py \\
        --p1 "This is a known message!" \\
        --c1 <hex from the handout> \\
        --c2 <hex from the handout>

Run with no arguments for a self-test on values generated here.
"""
import argparse
import os
import sys


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def recover(p1: bytes, c1: bytes, c2: bytes) -> bytes:
    n = min(len(p1), len(c1), len(c2))
    if len(c2) > n:
        print(f"note: P2 is longer than the known plaintext; only its first {n} "
              f"bytes can be recovered", file=sys.stderr)
    keystream = xor(p1[:n], c1[:n])
    return xor(c2[:n], keystream)


def self_test():
    from Crypto.Cipher import AES
    key, iv = os.urandom(16), os.urandom(16)
    p1 = b"This is a known message!"
    p2 = b"Order: Launch a missile!"
    # The mistake: one key, one IV, two messages.
    c1 = AES.new(key, AES.MODE_OFB, iv).encrypt(p1)
    c2 = AES.new(key, AES.MODE_OFB, iv).encrypt(p2)
    print("self-test (AES-128-OFB, IV deliberately reused)")
    print(f"  P1 (known)   : {p1.decode()}")
    print(f"  C1           : {c1.hex()}")
    print(f"  C2           : {c2.hex()}")
    got = recover(p1, c1, c2)
    print(f"  recovered P2 : {got.decode(errors='replace')}")
    print(f"  actual    P2 : {p2.decode()}")
    print(f"  RESULT       : {'PASS' if got == p2 else 'FAIL'}")
    print("\n  The key was never needed. Neither was the IV.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p1", help="known plaintext of message 1 (text)")
    ap.add_argument("--p1-hex", help="known plaintext of message 1 (hex)")
    ap.add_argument("--c1", help="ciphertext of message 1 (hex)")
    ap.add_argument("--c2", help="ciphertext of message 2 (hex)")
    args = ap.parse_args()

    if not (args.c1 and args.c2 and (args.p1 or args.p1_hex)):
        self_test()
        return

    p1 = bytes.fromhex(args.p1_hex) if args.p1_hex else args.p1.encode()
    c1 = bytes.fromhex(args.c1.replace(" ", ""))
    c2 = bytes.fromhex(args.c2.replace(" ", ""))

    p2 = recover(p1, c1, c2)
    print(f"P1  : {p1!r}")
    print(f"C1  : {c1.hex()}")
    print(f"C2  : {c2.hex()}")
    print(f"\nrecovered P2 : {p2.decode(errors='replace')!r}")
    if not all(32 <= b < 127 or b in (9, 10, 13) for b in p2):
        print("\nSome bytes are not printable. Re-check the hex you copied from "
              "the handout - a single mistyped digit corrupts exactly one byte.")


if __name__ == "__main__":
    main()
