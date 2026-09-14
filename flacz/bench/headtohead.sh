#!/usr/bin/env bash
# Head-to-head: how well does each codec model the PCM behind a real `flac -8` file?
# Decode each input .flac to WAV with the reference decoder, then compress that WAV with
# every competitor.
#
# Only files that EVERY listed codec handled are summed into the comparison totals --
# several competitors reject exotic formats (Sac is 1-16 bit mono/stereo only), and summing
# a codec's total over a different file set than another's would be meaningless.
# Per-codec coverage counts are printed so any exclusion is visible.
#
# flacz's own ratio never comes from here: it comes from verify.sh, which proves
# losslessness on the same run that reports it.
#
# Usage: bench/headtohead.sh [FILE...]      default: CORPUS-NATURAL
#        WITH_SAC=1 bench/headtohead.sh ... to include Sac (slow)
set -u
FLACB=/home/user/corpus/flacsrc/build/src/flac/flac
WVPK=/home/user/corpus/wavpack/build/wavpack
MAC=/home/user/corpus/mac/build/mac
SAC=/home/user/corpus/sac/sac
[ $# -eq 0 ] && set -- /home/user/corpus/natural/*.flac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; : > "$ROWS"
for f in "$@"; do
    o=$(stat -c%s "$f")
    "$FLACB" -d -s -f -o "$TMP/a.wav" "$f" 2>/dev/null || { echo "SKIP(decode) $f" >&2; continue; }
    w=0; m4=0; m5=0; s=0
    "$WVPK" -hh -q -y -o "$TMP/a.wv"  "$TMP/a.wav" >/dev/null 2>&1 && w=$(stat -c%s "$TMP/a.wv" 2>/dev/null || echo 0)
    "$MAC"  "$TMP/a.wav" "$TMP/a4.ape" -c4000 >/dev/null 2>&1 && m4=$(stat -c%s "$TMP/a4.ape" 2>/dev/null || echo 0)
    "$MAC"  "$TMP/a.wav" "$TMP/a5.ape" -c5000 >/dev/null 2>&1 && m5=$(stat -c%s "$TMP/a5.ape" 2>/dev/null || echo 0)
    if [ "${WITH_SAC:-0}" = 1 ]; then
        "$SAC" --normal "$TMP/a.wav" "$TMP/a.sac" >/dev/null 2>&1 && s=$(stat -c%s "$TMP/a.sac" 2>/dev/null || echo 0)
    fi
    echo "$o $w $m4 $m5 $s $(basename "$f")" >> "$ROWS"
    rm -f "$TMP"/a.wav "$TMP"/a4.ape "$TMP"/a5.ape "$TMP"/a.wv "$TMP"/a.sac
done
awk -v withsac="${WITH_SAC:-0}" '
{ n++; o[n]=$1; w[n]=$2; m4[n]=$3; m5[n]=$4; s[n]=$5;
  if($2>0)cw++; if($3>0)cm4++; if($4>0)cm5++; if($5>0)cs++; }
END{
  printf "head-to-head: %d files decoded\n", n;
  printf "coverage: wavpack %d/%d, mac-c4000 %d/%d, mac-c5000 %d/%d", cw,n,cm4,n,cm5,n;
  if(withsac=="1") printf ", sac %d/%d", cs,n;
  printf "\n";
  for(i=1;i<=n;i++){
    ok = (w[i]>0 && m4[i]>0 && m5[i]>0 && (withsac!="1" || s[i]>0));
    if(ok){ k++; to+=o[i]; tw+=w[i]; t4+=m4[i]; t5+=m5[i]; ts+=s[i]; }
  }
  printf "common subset all codecs handled: %d files, input .flac total %d bytes\n\n", k, to;
  printf "  %-28s %13s %10s\n","codec","bytes","vs flac -8";
  printf "  %-28s %13d %10s\n","flac -8 (the input)", to, "--";
  printf "  %-28s %13d %+9.2f%%\n","wavpack -hh", tw, 100.0*(tw-to)/to;
  printf "  %-28s %13d %+9.2f%%\n","mac -c4000 (High)", t4, 100.0*(t4-to)/to;
  printf "  %-28s %13d %+9.2f%%\n","mac -c5000 (Insane)", t5, 100.0*(t5-to)/to;
  if(withsac=="1") printf "  %-28s %13d %+9.2f%%\n","sac --normal", ts, 100.0*(ts-to)/to;
}' "$ROWS"
