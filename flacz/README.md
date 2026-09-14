# flacz

**Byte-exact lossless recompression of FLAC files.**

`flacz` takes a `.flac` file you already have, packs it into a smaller `.flz`, and puts the
**original `.flac` back byte-for-byte** — same bytes, same SHA-256, same tags, same
metadata, same everything. Your rip logs and checksums still match afterwards.

```
flacz c album.flac album.flz     # compress
flacz d album.flz album.flac     # restore -- byte-identical to the original
```

## Why this exists

FLAC is a good format that has been fully mined. On a file already encoded at `flac -8`,
the most exhaustive re-encode the reference encoder can do buys **0.10 %**, and running
`xz -9e` over the file buys **1.45 %**. That is the whole of what is available today.

Meanwhile, stronger audio models — Monkey's Audio, OptimFROG, Sac — compress the *same
audio* 8–10 % smaller than FLAC does. But using them means giving up your FLAC files.
Nobody had connected the two: model the audio properly, *and* keep enough information to
rebuild the original FLAC bitstream exactly.

That is what `flacz` does.

## Build

```
make
```

C11, no dependencies beyond libc.

## Verifying it really is lossless

Don't take the tool's word for it — `flacz`'s own exit code and output prove nothing.

```
bench/verify.sh FILE [FILE...]
```

For every file this stages a pristine copy the compressor is never pointed at, compresses a
*separate* working copy, then decompresses inside a **fresh empty directory containing only
the `.flz` and a copy of the binary**, as its own process — so nothing can leak in through a
side file, a cached dictionary, or any path outside that directory — and compares `cmp` plus
`sha256sum` against the pristine copy.

```
make verify          # CORPUS-NATURAL  -- ratio gate
make verify-stress   # CORPUS-STRESS   -- robustness gate
make speed           # throughput gate
```

## Status

See `PLAN.md` for the design and the numeric gates, `LOG.md` for the round-by-round record,
and `bench/BASELINES.md` for the measured competitive baselines.

## License

The FLAC test corpus used for verification is CC0 (IETF CELLAR FLAC decoder testbench by
Martijn van Beurden) and is not redistributed here.
