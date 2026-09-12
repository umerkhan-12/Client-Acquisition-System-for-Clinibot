#!/usr/bin/env python3
"""A local stand-in for Bob, the encryption oracle in Task 6.3.

The lab runs this as a network service you reach with `nc 10.9.0.80 3000`.
Same behaviour, no Docker needed:

  * Bob holds a secret message that is either "Yes" or "No".
  * He encrypts it with AES-128-CBC under a key you never see, using IV #n.
  * He will also encrypt ANY plaintext you hand him - the chosen-plaintext
    part - but he uses IV #n+1 for it, and he tells you what that IV is.

The IV is a counter. That is the whole bug.
"""
import os
import random
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad


class Bob:
    def __init__(self, secret=None, key=None, iv_start=None):
        self.key = key or os.urandom(16)
        self.secret = secret if secret is not None else random.choice([b"Yes", b"No"])
        # A predictable IV: a counter, which is exactly what real systems have
        # shipped (see the BEAST attack on TLS 1.0, same root cause).
        self.counter = iv_start if iv_start is not None else random.getrandbits(64)

    def _iv(self, n):
        return n.to_bytes(16, "big")

    def next_iv(self):
        """Bob publishes the IV he will use next. Or an attacker just guesses.

        The counter has already advanced past the messages sent so far, so the
        IV coming up is the counter's current value.
        """
        return self._iv(self.counter)

    def encrypt_secret(self):
        iv = self._iv(self.counter)
        ct = AES.new(self.key, AES.MODE_CBC, iv).encrypt(pad(self.secret, 16))
        self.counter += 1
        return iv, ct

    def encrypt_for_attacker(self, plaintext: bytes):
        iv = self._iv(self.counter)
        ct = AES.new(self.key, AES.MODE_CBC, iv).encrypt(pad(plaintext, 16))
        self.counter += 1
        return iv, ct
