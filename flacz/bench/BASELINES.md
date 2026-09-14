# Measured baselines (this machine: 4-core Xeon @ 2.80 GHz)

All numbers below were **measured here**, not cited, except where marked.

## A. What exists today for "shrink a .flac, restore it byte-exactly"
14 reference `flac -8` files from CORPUS-NATURAL, 7,255,497 bytes total.

| Option | Result | Byte-exact restore? |
|---|---:|:--:|
| `xz -9e` over the `.flac` | −1.45 % | yes |
| Python `lzma -9e` over the `.flac` | −1.45 % | yes |
| `flac -8pe -A "tukey(0.5);partial_tukey(2);punchout_tukey(3)"` | −0.10 % | **no** |

FLAC's own model is saturated: the most exhaustive re-encode the reference encoder offers
buys 0.10 % on a file already at `-8`.

## B. What better modelling reaches — locally built competitors
Single file `01 - blocksize 4096.flac` (reference `flac -8`, 547,403 bytes), decoded to WAV
and re-compressed:

| Codec | Bytes | vs `flac -8` | Enc. seconds |
|---|---:|---:|---:|
| `flac -8` (reference) | 547,403 | — | 0.028 |
| `wavpack -hh` | 540,570 | −1.25 % | 0.051 |
| `mac -c4000` (High) | 504,576 | −7.82 % | 0.061 |
| `mac -c5000` (Insane) | 502,464 | −8.21 % | 0.148 |
| `sac --normal` | 493,050 | **−9.93 %** | 3.442 |
| OptimFROG `--preset max` | *unobtainable here* | *−9.0 % (published)* | — |

Binaries: flac `/home/user/corpus/flacsrc/build/src/flac/flac`; wavpack
`/home/user/corpus/wavpack/build/wavpack`; mac `/home/user/corpus/mac/build/mac`;
sac `/home/user/corpus/sac/sac`.

## C. Recipe cost — the price of byte-exactness
From `flac --analyze` over 12 CORPUS-NATURAL files (874 frames, 1,748 subframes,
51,194,160 payload bits): the non-residual data a recipe must carry — frame headers,
subframe headers, LPC order/precision/shift/coefficients, warmup samples, Rice partition
orders and parameters — totals **487,255 bits = 0.95 % of the payload**, stored *raw*.

Observed parameter distribution (drives how compressible the recipe is):
- subframe types: LPC 1,723 / FIXED 25 / CONSTANT 0 / VERBATIM 0
- qlp precision: **12 bits for all 1,723 LPC subframes** (constant — nearly free to code)
- LPC orders: spread over 4–12, mode 4
- partition orders: 0 for 1,230 of 1,748 (70 %), rest ≤ 6

**Implication.** The recipe costs ~1 % raw and should compress well below that (precision is
constant, orders and partition orders are low-entropy). Against a 8–10 % modelling
opportunity, byte-exactness is affordable — which is the economic premise of the project.
