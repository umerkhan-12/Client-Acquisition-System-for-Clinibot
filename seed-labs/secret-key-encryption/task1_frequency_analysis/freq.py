#!/usr/bin/env python3
"""Task 1 helper: n-gram frequency counts of a ciphertext.

Same idea as the freq.py shipped in the SEED Labsetup: count single letters,
bigrams and trigrams so they can be lined up against English statistics.

    python3 freq.py ../Files/ciphertext.txt
"""
import sys
from collections import Counter

# Reference frequencies for English (percent), for side-by-side comparison.
ENGLISH_1GRAM = "etaoinshrdlcumwfgypbvkjxqz"
ENGLISH_2GRAM = ["th", "he", "in", "er", "an", "re", "on", "at", "en", "nd"]
ENGLISH_3GRAM = ["the", "and", "ing", "her", "hat", "his", "tha", "ere", "for", "ent"]


def ngrams(text, n):
    """Count n-grams inside words only; word boundaries are not crossed."""
    counter = Counter()
    for word in text.split():
        letters = "".join(c for c in word if c.isalpha())
        for i in range(len(letters) - n + 1):
            counter[letters[i:i + n]] += 1
    return counter


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "../Files/ciphertext.txt"
    text = open(path, encoding="utf-8", errors="ignore").read().lower()

    for n, reference in ((1, ENGLISH_1GRAM), (2, ENGLISH_2GRAM), (3, ENGLISH_3GRAM)):
        counter = ngrams(text, n)
        total = sum(counter.values())
        print(f"\n=== {n}-gram (top 10 of {len(counter)} distinct) ===")
        ref = list(reference)[:10] if n == 1 else list(reference)[:10]
        for rank, (gram, count) in enumerate(counter.most_common(10)):
            pct = 100.0 * count / total if total else 0.0
            print(f"  {rank + 1:2}. {gram:<4} {count:5}  {pct:5.2f}%   english #{rank + 1}: {ref[rank]}")

    # The single most useful line for a manual attack.
    single = ngrams(text, 1)
    order = "".join(g for g, _ in single.most_common())
    print("\nciphertext letters, most common first:", order)
    print("english   letters, most common first:", ENGLISH_1GRAM)


if __name__ == "__main__":
    main()
