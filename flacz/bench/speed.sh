#!/usr/bin/env bash
# Speed gate (PLAN.md §2.4). Throughput is measured in bytes of ORIGINAL .flac per second,
# single-threaded, plus peak RSS. Gates: decompress >= 1.0 MB/s, compress >= 0.4 MB/s,
# RSS <= 1 GB.
#
# Usage: bench/speed.sh [FILE...]   (default: CORPUS-NATURAL)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLACZ_BIN="${FLACZ_BIN:-$SCRIPT_DIR/../flacz}"
[ $# -eq 0 ] && set -- /home/user/corpus/natural/*.flac
[ -x "$FLACZ_BIN" ] || { echo "speed.sh: no binary at $FLACZ_BIN" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
total=0
for f in "$@"; do total=$((total + $(stat -c%s "$f"))); done

maxrss=0
t0=$(date +%s.%N)
i=0
for f in "$@"; do
    /usr/bin/time -f '%M' -o "$TMP/rss" "$FLACZ_BIN" c "$f" "$TMP/$i.flz" >/dev/null 2>&1
    r=$(tail -1 "$TMP/rss" 2>/dev/null || echo 0); [ "$r" -gt "$maxrss" ] 2>/dev/null && maxrss=$r
    i=$((i+1))
done
t1=$(date +%s.%N)

j=0
for f in "$@"; do
    /usr/bin/time -f '%M' -o "$TMP/rss" "$FLACZ_BIN" d "$TMP/$j.flz" "$TMP/$j.out" >/dev/null 2>&1
    r=$(tail -1 "$TMP/rss" 2>/dev/null || echo 0); [ "$r" -gt "$maxrss" ] 2>/dev/null && maxrss=$r
    j=$((j+1))
done
t2=$(date +%s.%N)

awk -v tot="$total" -v a="$t0" -v b="$t1" -v c="$t2" -v n="$#" -v rss="$maxrss" 'BEGIN{
  ce=b-a; de=c-b;
  printf "speed: %d files, %d bytes of original .flac\n", n, tot;
  printf "speed: compress   %7.2f s  -> %6.3f MB/s  (gate >= 0.400)  %s\n", ce, tot/ce/1e6, (tot/ce/1e6>=0.4?"PASS":"FAIL");
  printf "speed: decompress %7.2f s  -> %6.3f MB/s  (gate >= 1.000)  %s\n", de, tot/de/1e6, (tot/de/1e6>=1.0?"PASS":"FAIL");
  printf "speed: peak RSS   %7.1f MB  (gate <= 1024)  %s\n", rss/1024, (rss/1024<=1024?"PASS":"FAIL");
}'
