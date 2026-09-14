#!/usr/bin/env bash
# Head-to-head: how well does each codec model the PCM behind a real `flac -8` file?
# For each input .flac: decode to WAV with the reference decoder, then compress that WAV
# with every competitor. flacz's own number comes from verify.sh (which proves losslessness
# on the same run), not from here.
#
# Usage: bench/headtohead.sh [FILE...]   (default: CORPUS-NATURAL)
set -u
FLACB=/home/user/corpus/flacsrc/build/src/flac/flac
WVPK=/home/user/corpus/wavpack/build/wavpack
MAC=/home/user/corpus/mac/build/mac
SAC=/home/user/corpus/sac/sac
[ $# -eq 0 ] && set -- /home/user/corpus/natural/*.flac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
to=0; tw=0; tm4=0; tm5=0; ts=0; tf=0; nsamp=0; nch=0; nfile=0
for f in "$@"; do
    o=$(stat -c%s "$f"); to=$((to+o))
    "$FLACB" -d -s -f -o "$TMP/a.wav" "$f" 2>/dev/null || continue
    nfile=$((nfile+1))
    "$FLACB" -8 -s -f -o "$TMP/a.flac" "$TMP/a.wav" 2>/dev/null; tf=$((tf+$(stat -c%s "$TMP/a.flac")))
    "$WVPK" -hh -q -y -o "$TMP/a.wv" "$TMP/a.wav" 2>/dev/null && tw=$((tw+$(stat -c%s "$TMP/a.wv")))
    "$MAC" "$TMP/a.wav" "$TMP/a4.ape" -c4000 >/dev/null 2>&1 && tm4=$((tm4+$(stat -c%s "$TMP/a4.ape")))
    "$MAC" "$TMP/a.wav" "$TMP/a5.ape" -c5000 >/dev/null 2>&1 && tm5=$((tm5+$(stat -c%s "$TMP/a5.ape")))
    if [ "${WITH_SAC:-0}" = 1 ]; then
        "$SAC" "$TMP/a.wav" "$TMP/a.sac" --normal >/dev/null 2>&1 && ts=$((ts+$(stat -c%s "$TMP/a.sac")))
    fi
    rm -f "$TMP"/a.wav "$TMP"/a*.ape "$TMP"/a.wv "$TMP"/a.sac "$TMP"/a.flac
done
awk -v n="$nfile" -v o="$to" -v f="$tf" -v w="$tw" -v m4="$tm4" -v m5="$tm5" -v s="$ts" 'BEGIN{
 printf "head-to-head over %d files; input .flac total = %d bytes\n", n, o;
 printf "  %-34s %12s %10s\n","codec","bytes","vs input";
 split("flac -8|wavpack -hh|mac -c4000 (high)|mac -c5000 (insane)|sac --normal",nm,"|");
 split(f"|"w"|"m4"|"m5"|"s,vv,"|");
 for(i=1;i<=5;i++) if(vv[i]+0>0) printf "  %-34s %12d %+9.2f%%\n", nm[i], vv[i], 100.0*(vv[i]-o)/o;
}'
