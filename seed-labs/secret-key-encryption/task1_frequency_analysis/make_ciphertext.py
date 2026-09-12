#!/usr/bin/env python3
"""Build a practice ciphertext exactly the way the SEED lab builds its own.

The lab lowercases an English article and applies one random monoalphabetic
substitution over a-z, leaving spaces and punctuation untouched. That is what
makes the cipher breakable: word boundaries and letter statistics survive.

    python3 make_ciphertext.py            # writes Files/ciphertext.txt + key
"""
import os
import random
import string

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(HERE, "..", "Files")
SEED = 1337  # fixed so the exercise is reproducible


def main():
    plain = open(os.path.join(FILES, "article.txt"), encoding="utf-8").read().lower()

    letters = list(string.ascii_lowercase)
    shuffled = letters[:]
    rng = random.Random(SEED)
    while True:
        rng.shuffle(shuffled)
        # A letter mapping to itself would be a free gift to the attacker.
        if all(a != b for a, b in zip(letters, shuffled)):
            break

    table = str.maketrans("".join(letters), "".join(shuffled))
    cipher = plain.translate(table)

    open(os.path.join(FILES, "ciphertext.txt"), "w", encoding="utf-8").write(cipher)
    key_line = "".join(shuffled)
    with open(os.path.join(FILES, "answer_key.txt"), "w", encoding="utf-8") as fh:
        fh.write("plain : " + "".join(letters) + "\n")
        fh.write("cipher: " + key_line + "\n")

    print("wrote Files/ciphertext.txt (%d bytes)" % len(cipher))
    print("encryption key (plain -> cipher):", key_line)
    print("\nfirst 200 characters of the ciphertext:\n")
    print(cipher[:200])


if __name__ == "__main__":
    main()
