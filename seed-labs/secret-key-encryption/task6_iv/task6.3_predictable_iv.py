#!/usr/bin/env python3
"""Task 6.3 - a predictable IV breaks CBC's confidentiality.

CBC encrypts the first block as

    C1 = E_k(P1 XOR IV)

E_k is deterministic. So if I can choose a plaintext AND I know the IV that
will be used on it, I can force the input of the block cipher to be anything
I like - including whatever Bob's input was.

Bob encrypted his secret S with IV1, giving C = E_k(pad(S) XOR IV1).
He will encrypt my message Q with IV2, which he publishes. I send

    Q = IV2 XOR IV1 XOR pad("Yes")

so his cipher computes E_k(Q XOR IV2) = E_k(IV1 XOR pad("Yes")).

If that comes back equal to C, then pad(S) was pad("Yes"). One query, one
guess, no key recovery, and the secret is exposed. This is why CBC IVs must be
unpredictable, not merely unique.

    python3 task6.3_predictable_iv.py                 # demo against local Bob
    python3 task6.3_predictable_iv.py --iv1 <hex> --iv2 <hex> --ct <hex>
                                                      # craft Q for the real lab oracle
"""
import argparse
import sys

from Crypto.Util.Padding import pad
from bob_oracle import Bob

CANDIDATES = [b"Yes", b"No"]


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def craft(iv1: bytes, iv2: bytes, guess: bytes) -> bytes:
    """The chosen plaintext that tests 'was the secret `guess`?'"""
    return xor(xor(iv2, iv1), pad(guess, 16))


def demo(secret):
    bob = Bob(secret=secret)
    iv1, c_secret = bob.encrypt_secret()
    print(f"  Bob's IV1        : {iv1.hex()}")
    print(f"  Bob's ciphertext : {c_secret.hex()}")

    iv2 = bob.next_iv()
    print(f"  next IV (leaked) : {iv2.hex()}")

    answer = None
    for guess in CANDIDATES:
        q = craft(iv1, iv2, guess)
        used_iv, c_mine = bob.encrypt_for_attacker(q)
        assert used_iv == iv2, "Bob did not use the IV he advertised"
        match = c_mine[:16] == c_secret[:16]
        print(f'  guess {guess.decode():<4} -> my Q = {q.hex()}')
        print(f'                  my C = {c_mine[:16].hex()}  '
              f'{"MATCH" if match else "no match"}')
        if match:
            answer = guess
        # Bob's counter moved on; re-read the IV he will use for the next query.
        iv2 = bob.next_iv()

    print(f"\n  secret recovered : {answer.decode() if answer else 'UNKNOWN'}")
    print(f"  secret really was: {secret.decode()}")
    ok = answer == secret
    print(f"  RESULT           : {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iv1", help="IV Bob used for his secret (hex)")
    ap.add_argument("--iv2", help="IV Bob will use for your message (hex)")
    ap.add_argument("--ct", help="Bob's ciphertext (hex), optional")
    args = ap.parse_args()

    if args.iv1 and args.iv2:
        iv1 = bytes.fromhex(args.iv1.replace(" ", ""))
        iv2 = bytes.fromhex(args.iv2.replace(" ", ""))
        print("Send each of these to the oracle. The one whose first ciphertext")
        print("block equals Bob's ciphertext identifies his secret message.\n")
        for guess in CANDIDATES:
            print(f'  if secret == "{guess.decode()}"  send plaintext (hex): '
                  f'{craft(iv1, iv2, guess).hex()}')
        if args.ct:
            print(f'\n  compare against Bob\'s first block: '
                  f'{bytes.fromhex(args.ct.replace(" ", ""))[:16].hex()}')
        return

    print("=== Bob's secret is 'Yes' ===")
    a = demo(b"Yes")
    print("\n=== Bob's secret is 'No' ===")
    b = demo(b"No")
    print("\nboth cases identified correctly:", a and b)
    sys.exit(0 if (a and b) else 1)


if __name__ == "__main__":
    main()
