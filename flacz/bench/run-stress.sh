#!/usr/bin/env bash
# Robustness gate: CORPUS-STRESS, the IETF CELLAR testbench as-is, including
# uncommon/ and faulty/. Correctness only -- never a source of headline ratios.
C=/home/user/corpus/flac-test-files
exec "$(dirname "$0")/verify.sh" "$C"/subset/*.flac "$C"/uncommon/*.flac "$C"/faulty/*.flac
