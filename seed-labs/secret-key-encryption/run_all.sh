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

echo; echo "all tasks finished"
