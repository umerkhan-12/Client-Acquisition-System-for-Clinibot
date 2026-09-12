#!/usr/bin/env python3
"""Task 1: break a monoalphabetic substitution cipher automatically.

Frequency counting by hand gets the first few letters; it stalls after that.
This finishes the job the way an analyst does, only faster: the lab's cipher
leaves spaces and punctuation alone, so every ciphertext word keeps its
*pattern* of repeated letters. "mrrp" can only decrypt to a word shaped a-b-b-c
(book, feel, door, ...). Intersecting those constraints across the whole text
pins the key down.

    python3 solve_substitution.py ../Files/ciphertext.txt
    python3 solve_substitution.py ../Files/ciphertext.txt --dict ../Files/words.txt

Use it on the real Labsetup ciphertext.txt the same way.
"""
import argparse
import os
import re
import string
import sys
import time
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ALPHABET = string.ascii_lowercase


def pattern_of(word):
    """Canonical repetition pattern: 'letter' -> (0,1,2,2,1,3)."""
    seen, out = {}, []
    for ch in word:
        if ch not in seen:
            seen[ch] = len(seen)
        out.append(seen[ch])
    return tuple(out)


def load_dictionary(path):
    words = set()
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            w = line.strip().lower()
            if w and w.isalpha() and w.isascii():
                words.add(w)
    # Contractions and one-letter words the dictionary may miss.
    words.update({"a", "i", "the", "of", "to", "and", "in", "is", "it", "that"})
    return words


class Solver:
    def __init__(self, cipher_words, dictionary, time_budget=25.0):
        self.dictionary = dictionary
        self.by_pattern = defaultdict(list)
        for w in dictionary:
            self.by_pattern[pattern_of(w)].append(w)
        # Common words first: the search finds the real key sooner.
        common = ["the", "and", "that", "have", "for", "not", "with", "you", "this",
                  "but", "his", "from", "they", "she", "which", "there", "their",
                  "what", "about", "would", "been", "one", "all", "when", "who"]
        rank = {w: i for i, w in enumerate(common)}
        for pat in self.by_pattern:
            self.by_pattern[pat].sort(key=lambda w: (rank.get(w, 999), len(w), w))

        self.words = cipher_words          # list of (word, count), most frequent first
        self.deadline = time.time() + time_budget
        self.best = None
        self.best_score = -1

    def candidates(self, cword):
        return self.by_pattern.get(pattern_of(cword), [])

    def solve(self):
        """Iterative deepening on the number of words we allow ourselves to skip.

        Proper nouns and typos are not in the dictionary, so a perfect cover is
        usually impossible; the smallest number of skips that still explains the
        text is almost always the right key.
        """
        order = sorted(
            self.words,
            key=lambda wc: (len(self.candidates(wc[0])), -len(wc[0]), -wc[1]),
        )
        total_words = len(order)
        for max_skips in range(0, max(2, total_words // 3) + 1):
            self.nodes = 0
            found = self._dfs(order, 0, {}, {}, max_skips)
            if found:
                return found
            if time.time() > self.deadline:
                break
        return self.best

    def _dfs(self, order, idx, c2p, p2c, skips_left):
        if self.nodes % 4096 == 0 and time.time() > self.deadline:
            return None
        self.nodes += 1

        if idx == len(order):
            return dict(c2p)

        cword, count = order[idx]
        for pword in self.candidates(cword):
            ok = True
            added = []
            for c, p in zip(cword, pword):
                if c in c2p:
                    if c2p[c] != p:
                        ok = False
                        break
                elif p in p2c:
                    ok = False
                    break
                else:
                    c2p[c] = p
                    p2c[p] = c
                    added.append((c, p))
            if ok:
                # Track the deepest consistent partial mapping as a fallback.
                score = sum(cnt * len(w) for w, cnt in order[:idx + 1])
                if score > self.best_score:
                    self.best_score = score
                    self.best = dict(c2p)
                got = self._dfs(order, idx + 1, c2p, p2c, skips_left)
                if got:
                    return got
            for c, p in added:
                del c2p[c]
                del p2c[p]

        if skips_left > 0:
            got = self._dfs(order, idx + 1, c2p, p2c, skips_left - 1)
            if got:
                return got
        return None


def complete_mapping(c2p):
    """Fill letters the search never determined, so decryption is total."""
    mapping = dict(c2p)
    used = set(mapping.values())
    free = [p for p in ALPHABET if p not in used]
    for c in ALPHABET:
        if c not in mapping:
            mapping[c] = free.pop(0) if free else "?"
    return mapping


def decrypt(text, mapping):
    return "".join(mapping.get(ch, ch) if ch.isalpha() else ch for ch in text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ciphertext", nargs="?",
                    default=os.path.join(HERE, "..", "Files", "ciphertext.txt"))
    ap.add_argument("--dict", dest="dict_path",
                    default=os.path.join(HERE, "..", "Files", "words.txt"))
    ap.add_argument("--budget", type=float, default=25.0)
    args = ap.parse_args()

    raw = open(args.ciphertext, encoding="utf-8", errors="ignore").read().lower()
    dictionary = load_dictionary(args.dict_path)

    counts = Counter(re.findall(r"[a-z]+", raw))
    cipher_words = counts.most_common()
    print(f"ciphertext: {len(raw)} chars, {sum(counts.values())} words, "
          f"{len(cipher_words)} distinct")
    print(f"dictionary: {len(dictionary)} words")

    solver = Solver(cipher_words, dictionary, time_budget=args.budget)
    started = time.time()
    partial = solver.solve()
    elapsed = time.time() - started

    if not partial:
        print("no mapping found; try a longer --budget or a bigger dictionary")
        sys.exit(1)

    mapping = complete_mapping(partial)
    plaintext = decrypt(raw, mapping)

    words = re.findall(r"[a-z]+", plaintext)
    hits = sum(1 for w in words if w in dictionary)
    print(f"solved in {elapsed:.1f}s, {solver.nodes} search nodes, "
          f"{len(partial)}/26 letters pinned by the search")
    print(f"sanity check: {hits}/{len(words)} decrypted words are real English "
          f"({100.0 * hits / max(1, len(words)):.1f}%)")

    print("\n=== KEY ===")
    print("cipher : " + "".join(ALPHABET))
    print("plain  : " + "".join(mapping[c] for c in ALPHABET))
    print("\n(read it the other way round for the encryption key)")
    inverse = {v: k for k, v in mapping.items()}
    print("plain  : " + "".join(ALPHABET))
    print("cipher : " + "".join(inverse.get(p, "?") for p in ALPHABET))

    print("\n=== RECOVERED PLAINTEXT ===")
    print(plaintext)

    out = os.path.join(os.path.dirname(os.path.abspath(args.ciphertext)), "plaintext_recovered.txt")
    open(out, "w", encoding="utf-8").write(plaintext)
    print(f"\nwritten to {out}")


if __name__ == "__main__":
    main()
