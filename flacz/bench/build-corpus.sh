#!/usr/bin/env bash
# Builds CORPUS-NATURAL: decode each clean stress-corpus FLAC and re-encode it with the
# REFERENCE encoder at `flac -8`, i.e. what real-world FLAC files actually look like.
# Headline ratio claims come from this corpus only (PLAN.md §2.2).
set -u
FLAC=${FLAC:-/home/user/corpus/flacsrc/build/src/flac/flac}
SRC=${SRC:-/home/user/corpus/flac-test-files/subset}
OUT=${OUT:-/home/user/corpus/natural}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"; rm -f "$OUT"/*.flac
ok=0; skip=0
for f in "$SRC"/*.flac; do
    b=$(basename "$f" .flac)
    num=${b%% *}
    # 48-55 are metadata-torture files (giant PADDING/PICTURE/SEEKTABLE), not audio tests.
    case "$num" in 48|49|50|51|52|53|54|55) skip=$((skip+1)); echo "SKIP $b (metadata torture)"; continue;; esac
    if ! "$FLAC" -d -s -f -o "$TMP/a.wav" "$f" 2>/dev/null; then
        skip=$((skip+1)); echo "SKIP $b (decode failed)"; continue; fi
    if ! "$FLAC" -8 -s -f -o "$OUT/$b.flac" "$TMP/a.wav" 2>/dev/null; then
        skip=$((skip+1)); echo "SKIP $b (re-encode failed)"; continue; fi
    ok=$((ok+1))
done
echo "CORPUS-NATURAL: $ok built, $skip skipped -> $OUT"
du -sh "$OUT"
