#!/usr/bin/env bash
# Headline ratio gate: CORPUS-NATURAL (reference `flac -8` files). PLAN.md §2.2/§2.3.
exec "$(dirname "$0")/verify.sh" /home/user/corpus/natural/*.flac
