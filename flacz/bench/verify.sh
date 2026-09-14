#!/usr/bin/env bash
#
# bench/verify.sh -- independent, out-of-process losslessness gate for flacz.
#
# ADAPTED from the verify.sh supplied with this project (originally written for
# "pgnz"). The independence properties of the original are preserved exactly;
# only the following were changed:
#   * binary name     pgnz  -> flacz          (env: FLACZ_BIN)
#   * container ext   .pgnz -> .flz
#   * added a per-file ratio column, so the SAME run that proves losslessness
#     also produces the ratio numbers -- there is no second, unverified run
#     from which a ratio could be quoted.
#   * filenames containing spaces are handled (the FLAC testbench uses them).
#
# This script NEVER consults anything flacz prints about its own correctness.
# For each input file it:
#   1. copies it to a "pristine" location the compressor is never pointed at,
#      and sha256's that pristine copy;
#   2. compresses a separate working copy with `flacz c`;
#   3. builds a FRESH, EMPTY directory containing ONLY the resulting .flz
#      file and a copy of the flacz binary, cd's into it, and decompresses
#      there as its own separate process (so nothing can leak through a side
#      file, a cached dictionary, or a path outside that directory);
#   4. cmp's the decompressed output against the pristine copy AND compares
#      sha256 digests -- both must agree, independently of flacz's exit code
#      or anything it wrote to stdout/stderr.
#
# Usage:   bench/verify.sh FILE [FILE...]
# Env:     FLACZ_BIN=/path/to/flacz   (default: <project root>/flacz)
#          VERIFY_QUIET=1             (suppress per-file PASS lines)
# Prints:  "PASS <file> <orig> <comp> <saving%>" or "FAIL <file>: <reason>"
#          per file, then a final summary with the aggregate saving.
# Exit:    0 if every file passed, 1 if any file failed, 2 on setup errors.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
FLACZ_BIN="${FLACZ_BIN:-$PROJECT_ROOT/flacz}"

if [ "$#" -eq 0 ]; then
    echo "usage: $0 FILE [FILE...]" >&2
    exit 2
fi

if [ ! -e "$FLACZ_BIN" ]; then
    echo "verify.sh: flacz binary not found at '$FLACZ_BIN' (build it first with 'make')" >&2
    exit 2
fi
if [ ! -x "$FLACZ_BIN" ]; then
    echo "verify.sh: '$FLACZ_BIN' exists but is not executable" >&2
    exit 2
fi
# Resolve to an absolute path once, since every test case cd's elsewhere.
FLACZ_BIN="$(cd "$(dirname "$FLACZ_BIN")" >/dev/null 2>&1 && pwd)/$(basename "$FLACZ_BIN")"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_ORIG=0
TOTAL_COMP=0

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/flacz-verify.XXXXXX")"
cleanup() { rm -rf "$WORKROOT"; }
trap cleanup EXIT

flatten() {
    # Collapse a (possibly multi-line) diagnostic to one line for the FAIL summary.
    printf '%s' "$1" | tr '\n\r' '  ' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}

for src in "$@"; do
    if [ ! -e "$src" ]; then
        echo "FAIL $src: input does not exist"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    base="$(basename -- "$src")"
    case_dir="$(mktemp -d "$WORKROOT/case.XXXXXX")"
    pristine_dir="$case_dir/pristine"
    work_dir="$case_dir/work"
    empty_dir="$case_dir/empty"
    mkdir -p "$pristine_dir" "$work_dir" "$empty_dir"

    # 1. Pristine copy, sha256'd, in a directory flacz never sees.
    pristine="$pristine_dir/$base"
    if ! cp -- "$src" "$pristine"; then
        echo "FAIL $src: could not stage a pristine copy"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    sha_pristine="$(sha256sum -- "$pristine" | awk '{print $1}')"
    orig_size="$(stat -c%s -- "$pristine")"

    # 2. Compress a separate working copy (never the pristine one).
    working_in="$work_dir/$base"
    cp -- "$src" "$working_in"
    compressed="$work_dir/$base.flz"
    compress_out="$("$FLACZ_BIN" c "$working_in" "$compressed" 2>&1)"
    compress_rc=$?
    if [ "$compress_rc" -ne 0 ]; then
        echo "FAIL $src: compress exited $compress_rc: $(flatten "$compress_out")"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if [ ! -e "$compressed" ]; then
        echo "FAIL $src: compress exited 0 but produced no output file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    comp_size="$(stat -c%s -- "$compressed")"

    # 3. Fresh, EMPTY directory: only the .flz file and the flacz binary.
    cp -- "$compressed" "$empty_dir/$base.flz"
    cp -- "$FLACZ_BIN" "$empty_dir/flacz"
    chmod +x "$empty_dir/flacz"

    out_name="$base.out"
    decompress_out="$(cd "$empty_dir" && ./flacz d "$base.flz" "$out_name" 2>&1)"
    decompress_rc=$?
    decompressed="$empty_dir/$out_name"
    if [ "$decompress_rc" -ne 0 ]; then
        echo "FAIL $src: decompress exited $decompress_rc: $(flatten "$decompress_out")"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if [ ! -e "$decompressed" ]; then
        echo "FAIL $src: decompress exited 0 but produced no output file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # 4. Independent verification only: cmp + sha256. flacz's own exit code
    #    and output were already used above just to detect outright failure;
    #    nothing it *claims* about correctness is trusted here.
    cmp_out="$(cmp -- "$pristine" "$decompressed" 2>&1)"
    if [ $? -ne 0 ]; then
        echo "FAIL $src: cmp mismatch: $(flatten "$cmp_out")"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    sha_decompressed="$(sha256sum -- "$decompressed" | awk '{print $1}')"
    if [ "$sha_pristine" != "$sha_decompressed" ]; then
        echo "FAIL $src: sha256 mismatch (pristine $sha_pristine != roundtrip $sha_decompressed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # Ratio is recorded ONLY for files that just proved lossless, above.
    TOTAL_ORIG=$((TOTAL_ORIG + orig_size))
    TOTAL_COMP=$((TOTAL_COMP + comp_size))
    if [ -z "${VERIFY_QUIET:-}" ]; then
        awk -v f="$src" -v o="$orig_size" -v c="$comp_size" \
            'BEGIN{printf "PASS %s  orig=%d comp=%d saving=%+.2f%%\n", f, o, c, (o>0?100.0*(o-c)/o:0)}'
    fi
    PASS_COUNT=$((PASS_COUNT + 1))
done

echo "verify: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$TOTAL_ORIG" -gt 0 ]; then
    awk -v o="$TOTAL_ORIG" -v c="$TOTAL_COMP" -v n="$PASS_COUNT" \
        'BEGIN{printf "verify: aggregate over %d VERIFIED-LOSSLESS files: orig=%d comp=%d saving=%+.3f%%\n", n, o, c, 100.0*(o-c)/o}'
fi
[ "$FAIL_COUNT" -eq 0 ]
