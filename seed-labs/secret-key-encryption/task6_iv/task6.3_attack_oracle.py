#!/usr/bin/env python3
"""Task 6.3 against the lab's real encryption oracle.

The oracle is the SEED Labsetup's own `known_iv` program (the service behind
`nc 10.9.0.80 3000`). It prints Bob's ciphertext, the IV he used, and then --
the fatal part -- the IV it is about to use for *your* plaintext.

    # against the Docker service the lab starts
    python3 task6.3_attack_oracle.py --host 10.9.0.80 --port 3000

    # against a locally compiled copy of the same program
    g++ -std=c++17 -o known_iv known_iv.cpp -lcrypto
    python3 task6.3_attack_oracle.py --cmd ./known_iv

Because CBC computes C1 = E(P1 XOR IV), knowing the IV in advance lets us
choose a plaintext that forces the cipher's input to equal whatever Bob's
input was. If the ciphertext comes back equal to his, our guess was right.
"""
import argparse
import re
import socket
import subprocess
import sys
import time

from Crypto.Util.Padding import pad

CANDIDATES = [b"Yes", b"No"]


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


class Channel:
    """Line-oriented reader that also copes with the oracle's bare prompts."""

    def __init__(self, write, read_byte):
        self._write = write
        self._read_byte = read_byte
        self.buf = ""

    def read_until(self, pattern, timeout=15.0):
        """Patterns must anchor on the end of the line: this reads one byte at
        a time, so an unanchored hex class would match the first digit to
        arrive rather than the whole value."""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            if time.time() > deadline:
                raise TimeoutError(f"oracle never printed /{pattern}/; "
                                   f"buffer so far:\n{self.buf[-400:]}")
            ch = self._read_byte()
            if not ch:
                raise EOFError("oracle closed the connection")
            self.buf += ch.decode("utf-8", "replace")

    def send(self, text):
        self._write((text + "\n").encode())


def open_process(cmd):
    p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def write(data):
        p.stdin.write(data)
        p.stdin.flush()

    return Channel(write, lambda: p.stdout.read(1)), p


def open_socket(host, port):
    s = socket.create_connection((host, port), timeout=15)
    return Channel(lambda data: s.sendall(data), lambda: s.recv(1)), s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", help="local oracle to spawn, e.g. ./known_iv")
    ap.add_argument("--host", default="10.9.0.80")
    ap.add_argument("--port", type=int, default=3000)
    args = ap.parse_args()

    if args.cmd:
        chan, handle = open_process(args.cmd)
        print(f"oracle: local process {args.cmd!r}\n")
    else:
        chan, handle = open_socket(args.host, args.port)
        print(f"oracle: {args.host}:{args.port}\n")

    c_secret = bytes.fromhex(chan.read_until(r"ciphertex.?:\s*([0-9a-fA-F]+)\s*\n").group(1))
    iv1 = bytes.fromhex(chan.read_until(r"The IV used\s*:\s*([0-9a-fA-F]+)\s*\n").group(1))
    print(f"Bob's ciphertext : {c_secret.hex()}")
    print(f"IV he used (IV1) : {iv1.hex()}\n")

    answer = None
    for guess in CANDIDATES:
        iv2 = bytes.fromhex(chan.read_until(r"Next IV\s*:\s*([0-9a-fA-F]+)\s*\n").group(1))
        q = xor(xor(iv2, iv1), pad(guess, 16))
        chan.send(q.hex())
        c_mine = bytes.fromhex(
            chan.read_until(r"Your ciphertext:\s*([0-9a-fA-F]+)\s*\n").group(1))
        hit = c_mine[:16] == c_secret[:16]
        print(f'testing "{guess.decode()}"')
        print(f'  next IV (IV2)  : {iv2.hex()}')
        print(f'  my plaintext Q : {q.hex()}   = IV2 xor IV1 xor pad("{guess.decode()}")')
        print(f'  Bob returned   : {c_mine[:16].hex()}   '
              f'{"<-- MATCHES Bob s ciphertext" if hit else "no match"}\n')
        if hit:
            answer = guess

    if args.cmd:
        handle.kill()
    else:
        handle.close()

    if answer:
        print(f'Bob\'s secret message is "{answer.decode()}".')
        print("Recovered with one chosen-plaintext query per candidate, "
              "and without ever learning the key.")
        return 0
    print("No candidate matched - check that the oracle pads the same way.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
