#!/bin/bash
# Run every task in order and drop the output in results/.
#
#   ./run_all.sh
#
# Nothing here needs the SEED VM: the inputs are generated locally. To use the
# lab's own Labsetup files instead, drop them into Files/ and rerun.
set -u
cd "$(dirname "$0")"
mkdir -p results

echo "############ TASK 1  frequency analysis ############"
python3 task1_frequency_analysis/make_ciphertext.py
python3 task1_frequency_analysis/freq.py Files/ciphertext.txt
python3 task1_frequency_analysis/solve_substitution.py Files/ciphertext.txt

echo; echo "############ TASK 2  ciphers and modes ############"
bash task2_ciphers/task2.sh

echo; echo "############ TASK 3  ECB vs CBC ############"
python3 task3_ecb_vs_cbc/make_bmp.py
bash task3_ecb_vs_cbc/task3.sh

echo; echo "############ TASK 4  padding ############"
bash task4_padding/task4.sh

echo; echo "############ TASK 5  error propagation ############"
bash task5_error_propagation/task5.sh

echo; echo "############ TASK 6.1  IV reuse ############"
bash task6_iv/task6.1_iv_experiment.sh

echo; echo "############ TASK 6.2  keystream reuse ############"
python3 task6_iv/task6.2_keystream_reuse.py

echo; echo "############ TASK 6.3  predictable IV ############"
(cd task6_iv && python3 task6.3_predictable_iv.py)

echo; echo "############ TASK 7  dictionary brute force ############"
(cd task7_bruteforce && python3 task7_bruteforce.py)

# ---- the same tasks again, against the official SEED Labsetup data ----
if [ -d Files/official ]; then
  echo; echo "############ OFFICIAL LABSETUP DATA ############"

  echo; echo "--- Task 1: the lab's ciphertext.txt ---"
  python3 task1_frequency_analysis/solve_substitution.py Files/official/ciphertext.txt \
          --dict Files/words.txt --budget 45

  echo; echo "--- Task 3: the lab's pic_original.bmp ---"
  bash task3_ecb_vs_cbc/task3.sh ../Files/official/pic_original.bmp

  echo; echo "--- Task 6.2: the P1/C1/C2 from the lab manual ---"
  python3 task6_iv/task6.2_keystream_reuse.py --p1 "This is a known message!" \
      --c1 a469b1c502c1cab966965e50425438e1bb1b5f9037a4c159 \
      --c2 bf73bcd3509299d566c35b5d450337e1bb175f903fafc159

  echo; echo "--- Task 6.3: the real oracle, if it has been built ---"
  if [ -x ./known_iv ]; then
    python3 task6_iv/task6.3_attack_oracle.py --cmd ./known_iv
  else
    echo "    (build it first: g++ -std=c++17 -o known_iv known_iv.cpp -lcrypto,"
    echo "     from Labsetup/encryption_oracle/ - or use --host 10.9.0.80 --port 3000)"
    python3 task6_iv/task6.3_predictable_iv.py
  fi

  echo; echo "--- Task 7: the lab's ciphertext, IV and words.txt ---"
  python3 task7_bruteforce/task7_bruteforce.py --plaintext "This is a top secret." \
      --ciphertext 764aa26b55a4da654df6b19e4bce00f4ed05e09346fb0e762583cb7da2ac93a2 \
      --iv aabbccddeeff00998877665544332211 --words Files/official/words.txt
fi

echo; echo "all tasks finished"
