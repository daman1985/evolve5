# SPEC-R0 — `.flz` container, FLAC recipe, and the shared walk

**Author:** codec-architect (Claude Opus 5) · **Date:** 2026-09-14 · **Round:** R0
**Status:** normative for `codec-engineer`. Everything here except §3.7 (`PCM_RAW`) is
intended to be *final shape*; R1–R4 change codec payloads, never the container.

Everything in this document that describes FLAC was checked against
`/home/user/corpus/flacsrc/src/libFLAC/{stream_decoder.c,bitreader.c,bitwriter.c,format.c,lpc.c,fixed.c}`
at commit `e94ff9f`, and against all 91 files of
`/home/user/corpus/flac-test-files/` with a throwaway Python bitstream parser
(`scratchpad/probe.py`, `probe2.py`). Statements of fact carry a `[verified]` tag where a
probe produced them. Guesses are labelled as such.

---

## 0. The central simplification

`flacz` never has to agree with a FLAC decoder. It only has to satisfy

> **parse ∘ emit = identity on bytes.**

This is strictly weaker than "decode correctly", and it removes a whole class of hazards.
Example: `FLAC__lpc_restore_signal()` has a narrow path that accumulates the predictor in
**32-bit wrapping** arithmetic and a wide path that uses `int64_t`; the reference chooses
between them by a static bound. If we always use `int64_t` and some pathological stream
would have wrapped, our reconstructed samples differ from a reference decode — but our
re-emission is *self-consistent*, so the original bytes still come back exactly. The only
cost is a slightly worse-modelled sample stream. We therefore fix `int64_t` arithmetic
everywhere and never worry about matching the reference's overflow behaviour.

The second structural simplification: the compressor **re-emits every frame it parses and
byte-compares it against the original while compressing** (PLAN §2.6). Because the emitter
is literally the same function with `d = DIR_WRITE`, this is not a second implementation —
it is the identity check above, executed. Any parse error becomes a ratio cost, never a
correctness cost.

---

## 1. Verified facts about the corpus

| Fact | Evidence |
|---|---|
| All 91 corpus files parse end-to-end with the field layout in §2 except `faulty/11` | `[verified]` per-file probe |
| `faulty/11` has a metadata block declaring length 16777215 → overruns EOF | `[verified]` |
| Zero non-canonical UTF-8 coded frame numbers | `[verified]` 0 / 81 627 frames |
| Zero non-zero frame-footer padding bits | `[verified]` |
| Zero frame-header reserved bits set; zero subframe pad bits set | `[verified]` |
| Zero CRC-8 or CRC-16 mismatches | `[verified]` |
| `subset/27` (old Flake): blocking-strategy bit **0**, STREAMINFO min 576 ≠ max 4608 | `[verified]` |
| `faulty/08` codes blocksize **65536** (code 7, ext `0xFFFF`) — legal in the frame header, rejected by the reference decoder | `[verified]` |
| `uncommon/09` uses partition order 15 (32768 partitions of 1 sample) | `[verified]` |
| `uncommon/10`, `/11` and `faulty/06` have **no STREAMINFO**; their frames still declare their own bps/sample-rate, so they parse | `[verified]` |
| `faulty/11` has metadata block type 127 | `[verified]` |
| Escape partitions with raw width 0 occur (116× in `subset/`) | `[verified]` |

---

## 2. FLAC bitstream reference (normative for the walk)

Bit order is MSB-first throughout. All multi-bit fields are big-endian.

### 2.1 Stream

```
[ leading junk / ID3v2 / nothing ]     -> S_PREAMBLE
"fLaC"                                  (4 bytes; may be absent — uncommon/10, /11)
metadata block*                         -> S_METADATA
record*                                 -> S_CHUNKS (frames and opaque runs)
[ trailing junk ]                       -> S_TRAILER
```

### 2.2 Metadata block

```
 1 bit   last-metadata-block flag
 7 bits  block type   (0 STREAMINFO, 1 PADDING, 2 APPLICATION, 3 SEEKTABLE,
                       4 VORBIS_COMMENT, 5 CUESHEET, 6 PICTURE, 7..126 reserved, 127 invalid)
24 bits  body length in bytes
 body    (length bytes, byte-aligned)
```
STREAMINFO body (34 bytes) — only four fields matter to us:
`min_blocksize u16 @0`, `max_blocksize u16 @2`, then at byte 10 a packed run
`sample_rate u20 | channels u3 | bits_per_sample-1 u5 | total_samples u36`.
We use `bits_per_sample` and `sample_rate` only as the fallback source for frame-header
codes 0, and `min_blocksize != max_blocksize` only as a *prediction* hint (§4.3).

### 2.3 Frame header

| Offset | Width | Field |
|---|---|---|
| byte0 bits7..0, byte1 bits7..2 | 14 | sync `0b11111111111110` (`0x3FFE`) |
| byte1 bit1 | 1 | reserved (`R`), mandatory 0 |
| byte1 bit0 | 1 | blocking strategy (`B`) |
| byte2 bits7..4 | 4 | blocksize code |
| byte2 bits3..0 | 4 | sample-rate code |
| byte3 bits7..4 | 4 | channel code |
| byte3 bits3..1 | 3 | sample-size code |
| byte3 bit0 | 1 | reserved, mandatory 0 |
| next | 8..56 | coded number, UTF-8-like, 1–7 bytes |
| next | 0/8/16 | blocksize extension (present iff code 6 / 7) |
| next | 0/8/16 | sample-rate extension (present iff code 12 / 13 / 14) |
| next | 8 | **CRC-8** (poly `0x07`, init 0) over every preceding header byte |

**Blocksize code** → 0 reserved; 1 → 192; 2..5 → `576 << (c-2)`; 6 → 8-bit ext, `bs = ext+1`;
7 → 16-bit ext, `bs = ext+1`; 8..15 → `256 << (c-8)`.
Note `bs` can therefore be **65536** (`[verified]` in `faulty/08`): buffers must be sized
for 65536, not 65535.

**Sample-rate code** → 0 from STREAMINFO; 1..11 = {88200, 176400, 192000, 8000, 16000,
22050, 24000, 32000, 44100, 48000, 96000}; 12 → 8-bit ext ×1000; 13 → 16-bit ext ×1;
14 → 16-bit ext ×10; 15 invalid.

**Channel code** → 0..7: `c+1` independent channels. 8: left/side (ch1 is side).
9: right/side (ch**0** is side). 10: mid/side (ch1 is side). 11..15 reserved.
The side channel is coded with **bps + 1** bits.

**Sample-size code** → 0 from STREAMINFO; 1→8, 2→12, 3 reserved, 4→16, 5→20, 6→24, 7→32.

**Coded number** — a UTF-8-like code whose length is determined by the leading byte
(`0xxxxxxx`=1 … `1111110x`=6, `11111110`=7). The reference reader **does not check
canonicality** and the reference writers emit the canonical (shortest) form, holding
≤31 bits (uint32 path) or ≤36 bits (uint64 path). Whether the value means a *frame number*
or a *sample number* depends on `B` **and** on STREAMINFO: the reference treats the stream
as variable-blocksize if `B == 1` **or** (`STREAMINFO present` and `min_blocksize !=
max_blocksize`). The second clause is the old Flake signalling and is live in `subset/27`.
**This distinction does not affect byte-exactness at all** — we store the coded bytes — it
affects only how well R1+ can predict the value (§4.3).

### 2.4 Subframe header

```
 1 bit   pad / reserved, mandatory 0
 6 bits  type code t
 1 bit   wasted-bits flag
 if flag: unary(w-1)        (w-1 zeros then a 1)   => w = wasted bits, 1 <= w < bps
```
`t` → 0 CONSTANT; 1 VERBATIM; 2..7 reserved; 8..12 FIXED order `t-8`; 13..31 reserved;
32..63 LPC order `t-31`.
Effective width for the subframe body is `bps_eff = bps - w`, where `bps` already includes
the `+1` for a side channel.

### 2.5 Subframe bodies

- **CONSTANT**: one signed `bps_eff`-bit value. All `blocksize` output samples equal it.
- **VERBATIM**: `blocksize` signed `bps_eff`-bit samples.
- **FIXED(o)**: `o` signed `bps_eff`-bit warm-up samples, then a residual (§2.6) of
  `blocksize - o` values. Predictor:
  `p0=0`, `p1=s[i-1]`, `p2=2s[i-1]-s[i-2]`, `p3=3s[i-1]-3s[i-2]+s[i-3]`,
  `p4=4s[i-1]-6s[i-2]+4s[i-3]-s[i-4]`.
- **LPC(o)**: `o` signed `bps_eff`-bit warm-ups; 4 bits `precision-1` (value 15 is
  illegal → `precision` 1..15); 5 bits **signed** shift (negative is illegal); `o`
  signed `precision`-bit coefficients; then a residual of `blocksize - o` values.
  Predictor: `pred = (Σ_{j=0}^{o-1} qlp[j] · s[i-1-j]) >> shift`, accumulated in
  `int64_t`, `>>` arithmetic.

`s[i] = residual[i] + pred(i)`.

### 2.6 Residual

```
 2 bits  coding method   (0 = partitioned Rice, 4-bit params
                          1 = partitioned Rice2, 5-bit params
                          2,3 reserved)
 4 bits  partition order po
 for k in 0 .. (1<<po)-1:
     plen bits  parameter        (plen = 4 or 5)
     if parameter == (1<<plen)-1:          /* ESCAPE: 15 or 31 */
         5 bits raw width r
         n_k values, each signed r bits (r == 0 => zero values emitted, all residuals 0)
     else:
         n_k Rice(parameter) values
 where n_0 = (blocksize >> po) - predictor_order, n_{k>0} = blocksize >> po
```
Validity (same tests the reference applies; failing any of them ⇒ opaque-run fallback):
`blocksize % (1<<po) == 0` and `(blocksize >> po) >= predictor_order`.

Rice(k) of signed `v`: `u = (v << 1) ^ (v >> 63)` (arithmetic shift → zig-zag), then
`u >> k` zero bits, a `1` bit, then the low `k` bits of `u`. The reference reader rejects
`u > UINT32_MAX`, so the emitter must treat `u > 0xFFFFFFFF` as a fallback condition.

### 2.7 Frame footer

```
 pad to byte boundary with ZERO bits          (0..7 bits, value must be 0)
 16 bits CRC-16 (poly 0x8005, init 0) over EVERY byte of the frame from the 0xFF sync
```

---

## 3. `.flz` container

### 3.1 Conventions

- `u8`, `u16le`, `u32le` — fixed-width little-endian integers.
- `varint` — unsigned LEB128: 7 bits payload per byte, high bit = continuation.
- Every *sub-stream* (§3.6) is an independent MSB-first bit stream, zero-padded to a byte
  boundary at the end of each chunk piece.

### 3.2 File header

```
off  size  field
 0    4    magic  0x46 0x4C 0x5A 0x1A   ("FLZ\x1a")
 4    1    container_version = 1
 5    1    flags:  bit0 has_fLaC_magic
                   bit1 orig_crc32_present
                   bits2..7 reserved, MUST be 0
 6    -    varint  original_file_length          (bytes of the source .flac)
 -    4    u32le   orig_crc32  (CRC-32/ISO-HDLC of the whole source file)
                   — present iff flags bit1
 -    -    section*                              (to EOF)
```
`orig_crc32` is an *informational* integrity check. The decompressor MAY verify it and MUST
NOT rely on it for anything else (the losslessness authority is `bench/verify.sh`).

### 3.3 Sections

```
 u8     section_id
 u8     codec_id
 u8     codec_version
 varint payload_len          (0 = self-delimiting; legal only for S_CHUNKS)
 u8[]   payload
```

| id | name | present | notes |
|---|---|---|---|
| `0x01` | `S_PREAMBLE` | iff non-empty | bytes before `"fLaC"`, or before the first record if there is no `"fLaC"` |
| `0x02` | `S_METADATA` | iff `"fLaC"` present | metadata blocks |
| `0x03` | `S_CHUNKS` | always | the record streams; **always last but one**, `payload_len = 0` |
| `0x04` | `S_TRAILER` | iff non-empty | bytes after the last record; physically **after** `S_CHUNKS` |

Sections appear in the file in the order `PREAMBLE, METADATA, CHUNKS, TRAILER`. The
self-delimiting `S_CHUNKS` payload lets the encoder stream everything out in one pass with
no seek-back and no whole-file buffering.

`codec_id`/`codec_version` are per-section, so R1–R4 replace a payload encoding by bumping
one byte. `codec_id = 0` always means "stored raw" for that section.

### 3.4 `S_PREAMBLE`, `S_TRAILER`

`codec_id 0` = raw bytes. (R1+ may add `codec_id 1` = generic LZ, for ID3 art.)

### 3.5 `S_METADATA`

`codec_id 0` — **opaque**: payload is the raw byte range from just after `"fLaC"` to the
first record. Used when block framing cannot be trusted.

`codec_id 1` — **per-block** (the R0 default):
```
 varint n_blocks
 repeat n_blocks:
    u8      hdr_byte            (last_flag<<7 | type), stored verbatim
    varint  declared_length     (the 24-bit field, verbatim)
    u8      body_codec_id       (0 = raw)
    varint  stored_length
    u8[stored_length] body
 varint tail_length             (bytes between the last block and the first record; normally 0)
 u8[tail_length] tail
```
`declared_length` and `stored_length` are separate on purpose: a truncated final block
re-emits its original (wrong) length field while storing only the bytes that exist.
`body_codec_id` is the hook for R1+ per-type metadata codecs (PADDING run-length,
SEEKTABLE delta, etc.); R0 always writes 0.

**Region-splitting rule** (deterministic; the decompressor never re-derives it, it just
replays the stored framing):
1. `preamble_end` = offset of the first `"fLaC"` in the first 64 KiB, else 0.
2. If `"fLaC"` was found, walk metadata blocks from `preamble_end + 4`. Stop at the block
   with the last-flag set. If any block header or body would run past EOF, stop **before**
   that block and record what was walked so far; its bytes fall into the record stream.
3. `records_start` = where the walk stopped.
4. *(Optional ratio refinement, allowed but not required in R0)* if no parseable frame
   begins at `records_start`, retry with `codec_id 0` and `records_start` = the first
   offset ≥ `preamble_end + 4` at which **two consecutive** frames parse (or one frame
   parses and reaches EOF). This recovers `faulty/11`; skipping it costs ratio only.

### 3.6 `S_CHUNKS`

```
 u8 geom_codec_id, u8 geom_codec_version
 u8 pcm_codec_id,  u8 pcm_codec_version
 u8 code_codec_id, u8 code_codec_version
 u8 verb_codec_id, u8 verb_codec_version
 varint total_records
 chunk*                       (terminated by a chunk whose chunk_len is 0)

 chunk:
   varint chunk_len           (byte length of everything after this field; 0 = terminator)
   varint n_records
   varint len_geom ; u8[len_geom]
   varint len_pcm  ; u8[len_pcm]
   varint len_code ; u8[len_code]
   varint len_verb ; u8[len_verb]
```

There are exactly **four logical sub-streams**: `GEOM`, `PCM`, `CODE`, `VERB`. Each is the
concatenation of its per-chunk pieces. **Codec state persists across chunk boundaries** —
a chunk is a multiplexing device only, not a reset point. A codec that needs to flush (a
range coder) flushes at the end of each chunk piece and re-primes at the start of the next;
its *model* state carries over untouched.

Close a chunk when `n_records == 4096` or `len_pcm >= 4 MiB`, whichever comes first. This
bounds encoder and decoder RSS at roughly one chunk.

**Decode order within a chunk is fixed: `GEOM`, then `PCM`, then `CODE`.** This is
load-bearing: `GEOM` carries everything needed to compute the exact bit layout of `PCM`,
and placing `CODE` last means an R4 recipe codec may condition Rice parameters and LPC
coefficients on *already-decoded samples* — which is where most of the remaining recipe
cost can be recovered (§6.3). Do not move fields between `GEOM` and `CODE` without
re-checking this.

### 3.7 `PCM` sub-stream, `codec_id 0` (`PCM_RAW`) — **R0 only**

For each record of kind `FRAME`, for `ch = 0 .. channels-1`, `blocksize` samples, each
exactly `bps_eff(ch)` bits, two's complement, MSB-first, no padding anywhere except at the
end of a chunk piece.

```
 bps_eff(ch) = frame_bps + side_extra(ch) - wasted(ch)
 side_extra(ch) = 1 if (channel_code==8 && ch==1) || (channel_code==9 && ch==0)
                       || (channel_code==10 && ch==1)  else 0
 frame_bps      = from sample-size code, or STREAMINFO when the code is 0
```

**Sample domain.** A `PCM` sample is the *subframe-domain* signal: exactly the integer the
subframe codes, i.e. after the wasted-bits right shift and **before** channel
de-correlation. Every subframe type contributes `blocksize` samples, including CONSTANT
(whose value is therefore fully derivable and is *not* stored in the recipe) and VERBATIM.

This domain is chosen because it makes R0 exact by construction and because the wasted low
zero bits are never stored. R2's predictor may prefer true L/R; the transform is exact and
documented in §4.5, and switching domains is a `pcm_codec_id` change, not a container
change.

### 3.8 `VERB` sub-stream, `codec_id 0`

Raw concatenated bytes of every opaque run, in record order.

---

## 4. The recipe

### 4.1 `GEOM` record

```
 kind : 1 bit      0 = FRAME, 1 = OPAQUE RUN

 kind == OPAQUE:
     varint run_length            (bytes; taken sequentially from VERB)

 kind == FRAME:
     hdr_reserved_R      : 1 bit      byte1 bit1, verbatim
     blocking_strategy_B : 1 bit      byte1 bit0, verbatim
     blocksize_code      : 4 bits
     samplerate_code     : 4 bits
     channel_code        : 4 bits
     samplesize_code     : 3 bits
     hdr_reserved_P      : 1 bit      byte3 bit0, verbatim
     number_len          : 3 bits     1..7 (0 is illegal)
     number_bytes        : 8*number_len bits, the coded-number bytes verbatim
     blocksize_ext       : 8 bits if blocksize_code==6, 16 bits if ==7, else absent
     samplerate_ext      : 8 bits if samplerate_code==12,
                           16 bits if ==13 or ==14, else absent
     for ch in 0 .. channels-1:
         wasted_flag     : 1 bit
         wasted_m1       : 5 bits if wasted_flag     (w-1, 0..31)
```

`wasted` lives in `GEOM`, not `CODE`, precisely because `PCM` cannot be laid out without it.

### 4.2 `CODE` record — per frame, subframes in channel order

```
 subframe_type   : 6 bits           the literal 6-bit type field
 if LPC:
     qlp_prec_m1 : 4 bits           literal field value (never 15)
     qlp_shift   : 5 bits           0..31, non-negative
     qlp_coeff[order] : each signed (qlp_prec_m1+1) bits
 if FIXED or LPC:
     rice_method : 2 bits           0 or 1
     part_order  : 4 bits
     for k in 0 .. (1<<part_order)-1:
         param   : 4 bits (method 0) or 5 bits (method 1)
         if param == escape:  raw_width : 5 bits
```

### 4.3 What is stored, what is derived — and why

**Stored literally (cannot be derived):**

| Field | Why it cannot be derived |
|---|---|
| blocksize / sample-rate codes and their extensions | several codes express the same value (e.g. 4096 = code 12, or code 7 + ext 0x0FFF); the choice is the encoder's |
| channel code, sample-size code | ditto (code 0 vs. an explicit code both encode "16-bit") |
| coded-number bytes + length | the value's meaning depends on STREAMINFO; the encoding need not be canonical |
| `B`, `R`, `P` reserved bits | free bits an encoder may set |
| subframe type code | this *is* the encoder's modelling decision |
| wasted-bits flag and count | the encoder chose it; a subframe may declare fewer wasted bits than the data allows |
| qlp precision, shift, coefficients | the encoder's quantised LPC fit — not recoverable from the samples |
| Rice method, partition order, per-partition parameter / escape width | the encoder's rate decision |

**Derived, never stored:**

| Field | Derivation |
|---|---|
| frame sync `0x3FFE` | constant |
| **CRC-8** | recomputed over the emitted header bytes. Never stored — saves 8 bits/frame. A frame whose CRC-8 does not match on parse becomes an opaque run. |
| **CRC-16** | recomputed over the emitted frame bytes. Never stored — saves 16 bits/frame. Same fallback rule. |
| frame-footer padding | count = bits to the next byte boundary; value must be 0 (checked on parse) |
| warm-up samples (FIXED/LPC) | *are* `sig[ch][0 .. order-1]`, which come from `PCM` |
| CONSTANT value | *is* `sig[ch][0]`; all samples are equal by construction |
| VERBATIM samples | *are* `sig[ch][0 .. blocksize-1]` |
| **all residuals** | recomputed: `e[i] = s[i] - pred(i)` |
| channel count, frame bps, blocksize | decoded from the codes already in `GEOM` |

Residuals being derived is the entire product: they are ~99.5 % of a FLAC file's bytes and
the recipe replaces them with ~355 bits per frame (§6).

### 4.4 R0 recipe codecs

`geom_codec_id = code_codec_id = verb_codec_id = 0`: the fields above written as plain
MSB-first bit packing, in exactly the order listed. No entropy coding, no prediction.
R1 introduces `codec_id 1` for `GEOM`/`CODE` (adaptive binary range coder with the contexts
sketched in §6.3). The *field list and order do not change* — only how each field's bits
are produced. The `rc_id` context tag on every `rxfer_*` call (§5.2) is the hook.

---

### 4.5 The subframe-domain ↔ interleaved-PCM transform (for R2, not used in R0)

R0's `PCM` stream is in the subframe domain (§3.7). A later `pcm_codec_id` may prefer true
interleaved L/R. The transform is exact in both directions and uses only recipe fields, so
it can live entirely inside `pcm_block` without touching the container. Recorded here so
R2 does not have to re-derive it (and so it is reviewed once, not twice).

Let `sig[ch][i]` be the subframe-domain value and `u[ch][i] = sig[ch][i] << wasted[ch]`.

**Forward (what a FLAC decoder outputs):**

| `channel_code` | L | R |
|---|---|---|
| 0..7 (independent) | `u[ch]` per channel | — |
| 8 (left/side) | `u[0]` | `u[0] - u[1]` |
| 9 (right/side) | `u[1] + u[0]` | `u[1]` |
| 10 (mid/side) | `(t + u[1]) >> 1` where `t = (u[0] << 1) \| (u[1] & 1)` | `(t - u[1]) >> 1` |

**Inverse (what `flac_subframe` needs):**

| `channel_code` | `u[0]` | `u[1]` |
|---|---|---|
| 8 | `L` | `L - R` |
| 9 | `L - R` | `R` |
| 10 | `(L + R) >> 1` (arithmetic) | `L - R` |

then `sig[ch] = u[ch] >> wasted[ch]`.

The mid/side pair is exactly invertible: with `m = floor((L+R)/2)` and `s = L-R`,
`(L+R)` and `s` have the same parity, so `t = 2m + (s & 1) = L + R` and the forward map
returns `L` and `R` unchanged. All arithmetic is `int64_t`; `>>` is arithmetic. `u[1]` for
a 32-bit stream needs 33 bits, which is why `sig[]` is `int64_t`.

A codec working in the L/R domain must still right-shift by `wasted[ch]` at the end, and
that shift is exact because the discarded bits are zero by construction (the FLAC decoder
produced them by shifting left).

## 5. The shared walk

### 5.1 Direction

```c
typedef enum { DIR_READ = 0, DIR_WRITE = 1 } dir_t;
```
`d` is always the direction **relative to the FLAC bitstream**:

- `DIR_READ` — compressing. FLAC bits are read; recipe and PCM sub-streams are *written*.
- `DIR_WRITE` — decompressing. Recipe and PCM sub-streams are read; FLAC bits are *written*.

Every `rxfer_*` primitive therefore inverts `d` internally. That inversion is the single
reason one function body can serve both passes.

### 5.2 Primitives — the only places `d` is tested

```c
typedef struct bitio bitio;   /* FLAC-side bit cursor + running CRC-8 and CRC-16 */
typedef struct recio recio;   /* one .flz stream: META | GEOM | PCM | CODE | VERB */
typedef enum { RC_META, RC_KIND, RC_RUNLEN, RC_BSCODE, RC_SRCODE, RC_CHCODE, RC_SSCODE,
               RC_RESV, RC_NUMLEN, RC_NUMBYTE, RC_BSEXT, RC_SREXT, RC_WASTED,
               RC_SFTYPE, RC_QLPPREC, RC_QLPSHIFT, RC_QLPCOEF,
               RC_RMETHOD, RC_PARTORDER, RC_RPARAM, RC_ESCW, RC_NCTX } rc_id;
```

**FLAC bitstream.** `nbits == 0` must be a legal no-op for all of these.

```c
static inline void xfer_u    (bitio *b, dir_t d, uint32_t *v, int nbits);
static inline void xfer_u64  (bitio *b, dir_t d, uint64_t *v, int nbits);
static inline void xfer_s64  (bitio *b, dir_t d, int64_t  *v, int nbits);  /* two's complement */
static inline void xfer_unary(bitio *b, dir_t d, uint32_t *v);             /* v zeros, then a 1 */
static inline void xfer_rice (bitio *b, dir_t d, int64_t  *v, uint32_t k);
static inline void xfer_bytes(bitio *b, dir_t d, uint8_t  *p, size_t n);   /* byte-aligned */
```

**`.flz` streams.** Same `d`; the inversion happens inside.

```c
static inline void rxfer_u    (recio *r, dir_t d, uint32_t *v, int nbits, rc_id c);
static inline void rxfer_u64  (recio *r, dir_t d, uint64_t *v, int nbits, rc_id c);
static inline void rxfer_s    (recio *r, dir_t d, int32_t  *v, int nbits, rc_id c);
static inline void rxfer_vu   (recio *r, dir_t d, uint64_t *v, rc_id c);   /* LEB128 varint */
static inline void rxfer_bytes(recio *r, dir_t d, uint8_t  *p, size_t n, rc_id c);

/* variable-length: flag bit, then 5 bits of (w-1) iff the flag is set (§4.1) */
static inline void rxfer_wasted(recio *r, dir_t d, uint32_t *w, rc_id c);
```

Reference bodies. **This is the entire direction-dependence of the project:**

```c
static inline void xfer_u(bitio *b, dir_t d, uint32_t *v, int nbits) {
    if (d == DIR_READ) *v = bits_read(b, nbits);
    else               bits_write(b, *v, nbits);
}
static inline void rxfer_u(recio *r, dir_t d, uint32_t *v, int nbits, rc_id c) {
    if (d == DIR_READ) rec_put_u(r, *v, nbits, c);   /* compressing => recipe is written */
    else               *v = rec_get_u(r, nbits, c);
}
```

**Composites.** These exist so that no *call site* ever branches on direction.

```c
/* (A) a field copied verbatim between the FLAC bitstream and a recipe stream. The whole
       point is the source-then-sink ordering, which is opposite in the two passes.      */
static inline void carry_u(fctx *c, recio *r, uint32_t *v, int fbits, int rbits, rc_id id) {
    if (c->d == DIR_READ) { xfer_u(c->fb, DIR_READ,  v, fbits);
                            rxfer_u(r,    DIR_READ,  v, rbits, id); }
    else                  { rxfer_u(r,    DIR_WRITE, v, rbits, id);
                            xfer_u(c->fb, DIR_WRITE, v, fbits); }
}
static inline void carry_s    (fctx *c, recio *r, int32_t *v, int bits, rc_id id);   /* signed */
static inline void carry_bytes(fctx *c, recio *r, uint8_t *p, size_t n, rc_id id);

/* (B) a field present in the FLAC bitstream but NOT in the recipe: recomputed.
       On READ it is parsed and checked; a mismatch arms the fallback.
       On WRITE the computed value is emitted. One call site, one expression.           */
static inline void derive_u64(fctx *c, uint64_t computed, int nbits) {
    uint64_t v = computed;
    xfer_u64(c->fb, c->d, &v, nbits);
    if (c->d == DIR_READ && v != computed) c->fallback = 1;
}
static inline void derive_s64(fctx *c, int64_t computed, int nbits);   /* same, signed */

/* (C) the predictor/residual coupling (see §5.6) */
static inline void xfer_pred_rice(fctx *c, int64_t *s, int64_t pred, uint32_t k) {
    int64_t e;
    if (c->d == DIR_WRITE) { e = *s - pred; xfer_rice(c->fb, DIR_WRITE, &e, k); }
    else                   { xfer_rice(c->fb, DIR_READ, &e, k); *s = e + pred; }
}
static inline void xfer_pred_raw(fctx *c, int64_t *s, int64_t pred, int rawbits) {
    int64_t e = 0;
    if (c->d == DIR_WRITE) { e = *s - pred; if (rawbits) xfer_s64(c->fb, DIR_WRITE, &e, rawbits); }
    else                   { if (rawbits) xfer_s64(c->fb, DIR_READ, &e, rawbits); *s = e + pred; }
}

/* (D) the wasted-bits flag + unary count. The VALUE lives in ctx (it is carried to GEOM
       by sig_pre/sig_post, §5.7); here only the FLAC-side encoding is transferred.
       Note there is no `if (d ...)` at all: both reads are out-params.                  */
static inline void xfer_wasted(fctx *c, uint32_t *w) {
    uint32_t flag = (*w != 0);
    xfer_u(c->fb, c->d, &flag, 1);            /* READ overwrites flag; WRITE emits it   */
    if (flag) { uint32_t u = *w ? *w - 1 : 0;
                xfer_unary(c->fb, c->d, &u);  /* READ overwrites u;    WRITE emits it   */
                *w = u + 1; }
    else *w = 0;
}
```

**The sanctioned set is exactly: `xfer_*`, `rxfer_*`, `carry_*`, `derive_*`,
`xfer_pred_*`, `xfer_wasted`, and the `sig_pre` / `sig_post` pair of §5.7. A direction test
anywhere else in the codebase is a defect (PLAN §2.5) even if every test passes.**

### 5.3 Context

```c
typedef struct {
    dir_t     d;
    bitio    *fb;
    recio    *meta, *geom, *pcm, *code, *verb;

    int       has_streaminfo;
    uint32_t  si_bps, si_sample_rate, si_min_bs, si_max_bs;
    int       number_is_sample_number;   /* B==1 || (has_streaminfo && min!=max); prediction only */
    uint32_t  meta_avail;                /* DIR_READ: bytes left in the metadata region;
                                            DIR_WRITE: UINT32_MAX                        */
    /* per-frame */
    uint32_t  blocksize, channels, frame_bps, channel_code;
    uint32_t  wasted[8];
    int64_t  *sig[8];                    /* 8 x 65536 int64 = 4 MiB, allocated once      */

    uint64_t  prev_number; uint32_t prev_blocksize;   /* prediction only */
    int       fallback;
} fctx;

typedef struct { uint32_t order; int is_lpc, prec, shift; int32_t qlp[32]; } pred_t;

static inline uint32_t side_extra(const fctx *c, uint32_t ch) {
    return ((c->channel_code == 8  && ch == 1) ||
            (c->channel_code == 9  && ch == 0) ||
            (c->channel_code == 10 && ch == 1)) ? 1u : 0u;
}
static inline uint32_t sub_bps(const fctx *c, uint32_t ch) {    /* BEFORE wasted-bit reduction */
    return c->frame_bps + side_extra(c, ch);
}
static inline uint32_t bps_eff(const fctx *c, uint32_t ch) {    /* AFTER  wasted-bit reduction */
    return sub_bps(c, ch) - c->wasted[ch];
}
```

### 5.4 Structural functions

```c
bool flacz_stream        (fctx *c);                  /* sections + the record loop         */
bool flac_metadata_block (fctx *c);                  /* one metadata block; returns last-flag */
bool flac_record         (fctx *c);                  /* GEOM `kind` dispatch               */
bool flac_frame          (fctx *c);                  /* one parsed frame, sync .. CRC-16   */
bool flac_frame_header   (fctx *c);
bool flac_subframe       (fctx *c, uint32_t ch);
bool flac_residual       (fctx *c, int64_t *s, uint32_t blocksize, const pred_t *p);
void sig_xfer            (fctx *c);                  /* wasted[] + all channels of PCM     */
void pcm_block           (fctx *c, uint32_t ch, uint32_t bps_eff);
static inline int64_t predict(const pred_t *p, const int64_t *s, uint32_t i);  /* ONE copy */
```

`flac_metadata_block` is genuinely symmetric:

```c
bool flac_metadata_block(fctx *c) {
    uint32_t hdr, declared, stored;
    carry_u(c, c->meta, &hdr,      8,  8, RC_META);        /* last_flag<<7 | type */
    carry_u(c, c->meta, &declared, 24, 24, RC_META);
    stored = declared < c->meta_avail ? declared : c->meta_avail;  /* DIR_WRITE: == declared,
                                                   and the rxfer below overwrites it anyway */
    rxfer_u(c->meta, c->d, &stored, 24, RC_META);
    carry_bytes(c, c->meta, body, stored, RC_META);
    c->meta_avail -= 4 + stored;
    return (hdr >> 7) != 0;
}
```

### 5.5 How one body serves both directions

```c
bool flac_subframe(fctx *c, uint32_t ch) {
    uint32_t t, bps = sub_bps(c, ch), i, j;
    int64_t *s = c->sig[ch];

    derive_u64(c, 0, 1);                                  /* mandatory 0 pad bit         */
    carry_u(c, c->code, &t, 6, 6, RC_SFTYPE);             /* type code                   */
    xfer_wasted(c, &c->wasted[ch]);                       /* FLAC-side encoding only     */
    if (c->wasted[ch] >= bps) { c->fallback = 1; return false; }
    bps -= c->wasted[ch];

    switch (classify(t)) {                                /* §2.4; reserved => fallback  */
    case SF_CONSTANT:
        derive_s64(c, s[0], bps);                         /* value IS s[0]               */
        break;
    case SF_VERBATIM:
        for (i = 0; i < c->blocksize; i++)
            xfer_s64(c->fb, c->d, &s[i], bps);            /* same call both directions   */
        break;
    case SF_FIXED: case SF_LPC: {
        pred_t p = { .order = order_of(t), .is_lpc = is_lpc(t) };
        for (i = 0; i < p.order; i++)
            xfer_s64(c->fb, c->d, &s[i], bps);            /* warm-ups ARE samples        */
        if (p.is_lpc) {
            uint32_t pm1;
            carry_u(c, c->code, &pm1,     4, 4, RC_QLPPREC);
            if (pm1 == 15) { c->fallback = 1; return false; }
            p.prec = pm1 + 1;
            carry_u(c, c->code, &p.shift, 5, 5, RC_QLPSHIFT);   /* 5-bit signed field;
                                                        a negative value => fallback     */
            for (j = 0; j < p.order; j++)
                carry_s(c, c->code, &p.qlp[j], p.prec, RC_QLPCOEF);
        }
        flac_residual(c, s, c->blocksize, &p);
        break; }
    }
    return !c->fallback;
}
```

Three things to notice, because they are why this works at all:

- **Warm-ups and VERBATIM samples need no recipe entry and no branch.** A warm-up *is* a
  sample. `xfer_s64(c->fb, c->d, &s[i], bps)` fills `s[i]` from the bitstream on `DIR_READ`
  and emits the `s[i]` that `sig_xfer` already loaded on `DIR_WRITE`. Same line.
- **CONSTANT's value is a `derive_*`,** because it is `s[0]` by construction.
- **Every encoder *decision*** (type, precision, shift, coefficients, Rice parameters) goes
  through `carry_*`, i.e. it round-trips through `CODE`. Every *consequence* of those
  decisions goes through `derive_*` or `xfer_pred_*`.

### 5.6 The residual asymmetry, and why it is still one walk

Parsing reads residuals and reconstructs samples; emitting knows samples and recomputes
residuals. These are not two algorithms — they are the same recurrence solved for different
unknowns, around a predictor that is identical.

```c
bool flac_residual(fctx *c, int64_t *s, uint32_t bs, const pred_t *p) {
    uint32_t m, po, k, param, rw, i, n;
    carry_u(c, c->code, &m,  2, 2, RC_RMETHOD);
    if (m > 1) { c->fallback = 1; return false; }
    carry_u(c, c->code, &po, 4, 4, RC_PARTORDER);
    if ((bs & ((1u << po) - 1)) || ((bs >> po) < p->order)) { c->fallback = 1; return false; }
    const int plen = m ? 5 : 4, esc = (1 << plen) - 1;
    i = p->order;
    for (k = 0; k < (1u << po); k++) {
        carry_u(c, c->code, &param, plen, plen, RC_RPARAM);
        n = (k == 0) ? (bs >> po) - p->order : (bs >> po);
        if (param == esc) {
            carry_u(c, c->code, &rw, 5, 5, RC_ESCW);
            for (; n--; i++) xfer_pred_raw (c, &s[i], predict(p, s, i), rw);
        } else {
            for (; n--; i++) xfer_pred_rice(c, &s[i], predict(p, s, i), param);
        }
    }
    return true;
}
```

`predict()` — the expensive, bug-prone part — exists in exactly one copy and is called
identically in both passes. The direction shows up only inside `xfer_pred_*`. The
reconstruction `s[i] = e + pred` and the computation `e = s[i] - pred` are two lines of one
function, not two functions.

This works because the recurrence is **causal**: `predict(p, s, i)` reads only
`s[i-order .. i-1]`, which are already final in both directions — on `DIR_READ` because
earlier iterations wrote them, on `DIR_WRITE` because `sig_xfer` loaded the whole block
before the walk began.

### 5.7 The one scheduling asymmetry — stated plainly

Sample data must exist *before* `flac_subframe` runs under `DIR_WRITE`, and only exists
*after* it runs under `DIR_READ`. There is no way to make that symmetric: the dependency
genuinely points in opposite directions. The same is true of the per-channel wasted-bit
counts, which `PCM`'s bit layout depends on but which the FLAC bitstream only reveals
inside each subframe header.

Both are handled by one matched pair of one-line primitives at the frame level:

```c
static void sig_xfer(fctx *c) {                 /* ONE copy of the body */
    for (uint32_t ch = 0; ch < c->channels; ch++)
        rxfer_wasted(c->geom, c->d, &c->wasted[ch], RC_WASTED);   /* flag + 5 bits, §4.1 */
    for (uint32_t ch = 0; ch < c->channels; ch++)
        pcm_block(c, ch, bps_eff(c, ch));
}
static inline void sig_pre (fctx *c) { if (c->d == DIR_WRITE) sig_xfer(c); }
static inline void sig_post(fctx *c) { if (c->d == DIR_READ ) sig_xfer(c); }

bool flac_frame(fctx *c) {
    bitio_frame_begin(c->fb);                       /* reset running CRC-8 / CRC-16      */
    if (!flac_frame_header(c)) return false;        /* GEOM: geometry codes + CRC-8      */
    sig_pre(c);                                     /* DIR_WRITE: wasted[] then sig[][]  */
    for (uint32_t ch = 0; ch < c->channels; ch++)
        flac_subframe(c, ch);
    derive_u64(c, 0, bits_to_byte_boundary(c->fb)); /* zero padding, 0..7 bits           */
    derive_u64(c, bitio_crc16(c->fb), 16);          /* frame CRC-16                      */
    sig_post(c);                                    /* DIR_READ: wasted[] then sig[][]   */
    return !c->fallback;
}
```

`sig_xfer()` exists in **one** copy; only *when* it is called differs. This is a scheduling
branch, not a logic branch: no code is duplicated, so nothing can drift. It is called out
here so the auditor can grep for exactly `sig_pre` / `sig_post` and confirm they are the
only such pair.

`flac_frame_header` is fully symmetric — a run of `carry_u` / `carry_bytes` against `GEOM`
in the §4.1 order, closed by `derive_u64(c, bitio_crc8(c->fb), 8)`.

Note the consequence for cursor order: within a frame, `GEOM` is touched by
`flac_frame_header` and `sig_xfer`, `PCM` by `sig_xfer`, and `CODE` by `flac_subframe` —
so `GEOM`, then `PCM`, then `CODE`, exactly as §3.6 requires, with three independent
sequential cursors and no look-ahead pass over the chunk.


### 5.8 Encode-time verification and rollback

Under `DIR_READ`, after `flac_frame` returns:

1. Take marks on all four sub-stream writers **before** the frame (`recio_mark`).
2. Build a scratch `fctx` with `d = DIR_WRITE`, reading the sub-streams back from the
   marks, writing FLAC bits into a scratch buffer.
3. `memcmp` against the original frame bytes.
4. On mismatch — or if `c->fallback` was armed at any point — `recio_rewind` all four
   writers to the marks and re-emit the frame as an `OPAQUE` record.

**Requirement on `recio`:** `mark`/`rewind` must restore *model* state as well as byte
position. At R0 (codec 0) the models are empty and this is trivial; from R1 the engineer
must either snapshot model state at each mark or run the trial pass against a copy. This
must be designed in from R0 — retrofitting it into an adaptive coder is painful.

---

## 6. Cost

### 6.1 Measured, on CORPUS-NATURAL (`flac -8`)

Two cuts of `/home/user/corpus/natural/` (the stress corpus decoded and re-encoded with
reference `flac -8`), measured by parsing every frame and adding up the §4 field widths
`[verified]`:

| Cut | files | frames | raw recipe | % of source `.flac` | payload |
|---|---:|---:|---:|---:|---:|
| **CD audio** (01–10: 44.1 kHz, 16-bit, stereo) | 10 | 760 | **262.5 bits/frame** | **0.452 %** | 57 193 bits/frame |
| **Files 01–29** (adds odd rates, 8/12/20/24-bit, 96 kHz) | 29 | 2 978 | **355.0 bits/frame** | **0.490 %** | 71 778 bits/frame |

Breakdown for the CD-audio cut, bits per frame (two subframes per frame):

| Field | bits/frame | % of recipe |
|---|---:|---:|
| LPC coefficients | 165.6 | 63.1 |
| Rice parameters | 22.8 | 8.7 |
| subframe type codes | 12.0 | 4.6 |
| qlp shift | 9.9 | 3.8 |
| coded-number bytes | 8.0 | 3.0 |
| partition order | 8.0 | 3.0 |
| qlp precision | 7.9 | 3.0 |
| blocksize / samplerate / channel / samplesize codes | 15.0 | 5.7 |
| Rice method | 4.0 | 1.5 |
| number length, reserved bits, wasted flags, `kind` bit, extensions | 9.2 | 3.5 |

The wider 01–29 cut shifts weight further onto LPC coefficients (235.7 b/f, 66.4 %) and
Rice parameters (43.1 b/f, 12.2 %) because higher bit depths use longer predictors and
higher partition orders. The shape of the problem does not change.

Note the recipe cost scales with **subframes**, not samples: an 8-channel frame pays ~8×
the per-subframe cost against ~8× the payload, so the *percentage* is roughly stable, but
a small-blocksize stream pays the per-frame floor many more times (§6.3).

### 6.2 Where the bits are, and the honest projection

Two fields are two-thirds of the recipe, and both are compressible:

- **LPC coefficients (166 b/f CD, 236 b/f wider cut — ~64 % of the recipe).** Structured: `qlp[0]` is large and positive, magnitudes
  decay, and successive frames of the same channel are strongly correlated. A context model
  on (coefficient index, precision, previous frame's coefficient) should reach 50–65 % of
  raw. From R4, the decompressor already has the samples when it decodes `CODE`, so it can
  run its own LPC fit and code the *difference* — potentially much better, but unproven.
- **Rice parameters (23 b/f CD, 43 b/f wider cut).** Nearly free from R4: with the samples and the predictor
  known, the decompressor can compute each partition's optimal parameter and the stored
  value is usually within ±1 of it. Expect 80–90 % reduction.
- **Everything else (~74 b/f CD, ~76 b/f wider cut)** is near-constant per stream: 85–95 % reduction under a
  simple adaptive model, coded-number included (predict `prev + 1` or `prev + blocksize`
  per §4.3's rule; the delta is 0 almost always).

Projection: **262 → 110–140 bits/frame** on CD audio (**0.19–0.24 % of the source
`.flac`**), **355 → 150–190** on the wider cut. At
the PLAN's 7 % target that is ~3 % of the win — real, worth R4's attention, and not a
threat to the target. I do not believe it goes much below ~110 b/f (CD) without predicting
LPC coefficients from the decoded signal, which is R4 speculation, not a plan — and if R4
tries it and fails, the honest outcome is to say so and keep the 0.2 %.

### 6.3 Two pathological cases worth knowing about

- **Partition order 15** (`uncommon/09`): 32 768 parameters × 4 bits = 131 kbit of recipe in
  one subframe. It is correct and it is rare; no special handling.
- **Blocksize 1** (`faulty/09`): 41 519 frames in a 587 kB file, ~40 bits of GEOM each.
  The per-frame recipe floor dominates for tiny blocksizes. Also rare.

Both are CORPUS-STRESS only and must never appear in a headline number (PLAN §2.2).

---

## 7. Exactness: the argument, and every hole I know of

### 7.1 The argument

Every bit of a FLAC frame falls into exactly one of five classes:

1. a field stored verbatim in `GEOM`/`CODE` (§4.3 table 1);
2. a sample value taken from `PCM` — warm-ups, VERBATIM samples, CONSTANT's value;
3. a residual, determined by `s[i] - predict(i)` with fully specified `int64_t` arithmetic
   and arithmetic right shift;
4. zero padding, whose length is determined by the bit position;
5. CRC-8 / CRC-16, pure functions of 1–4.

Rice(k) and signed-`r`-bit codes are bijections on their domains, so classes 3 and 2 have
unique encodings. Classes 1, 4, 5 are literal. Therefore the emitted byte string is a
function of (recipe, samples) alone — deterministic, and independent of anything outside
the `.flz`.

The residual claim needs one more step, and it is the step the whole project rests on:
on `DIR_READ` we computed `s[i] = e[i] + predict(i)` with the *same* `predict()`; therefore
`s[i] - predict(i) = e[i]` exactly, for the same sample history. The history is identical
because it is reconstructed in the same order by the same recurrence. Integer arithmetic
is exact, so there is no rounding to disagree about.

### 7.2 Holes — things I am not certain about

Each of these is covered by the opaque-run fallback (§8), which converts it from a
correctness risk into a ratio risk. That is the point of the fallback; it is not a
hand-wave, but I list the cases explicitly so nobody assumes they are handled cleverly.

| # | Case | Status |
|---|---|---|
| 1 | Original CRC-8 or CRC-16 is **wrong**. We never store them, so such a frame cannot round-trip through the recipe. | Parser requires both to match ⇒ opaque run. 0 occurrences in 91 files `[verified]`. |
| 2 | Frame-footer padding bits non-zero. Not stored. | Checked on parse ⇒ opaque run. 0 occurrences `[verified]`. |
| 3 | Subframe pad bit (bit 7) set. Not stored. | Checked ⇒ opaque run. 0 occurrences `[verified]`. Note the two *frame-header* reserved bits **are** stored, so those cost nothing. |
| 4 | Non-canonical UTF-8 coded number. | Handled by storing raw bytes + length. 0 occurrences `[verified]`, handled anyway. |
| 5 | **Old Flake variable blocksize** (`B`=0, STREAMINFO min≠max). | Not an exactness issue at all — we store the coded bytes. Only the R1+ number predictor needs the rule, which is stated in §4.3 and verified against `subset/27`. |
| 6 | **32-bit audio / 33-bit side channels.** `bps_eff` reaches 33 and residuals need >32 bits of headroom. | `sig[]` is `int64_t` throughout; `PCM_RAW` writes 33-bit samples. `uncommon/05` parses `[verified]`. Emitter must reject zig-zag values > `UINT32_MAX` (the reference reader's limit) ⇒ opaque run. |
| 7 | **Rice escape with width 0.** Emits nothing; all residuals must be 0. | `xfer_pred_raw(rawbits=0)` sets `e=0`. If the recomputed residual were non-zero the frame would differ ⇒ caught by verification ⇒ opaque run. 116 occurrences in `subset/` `[verified]`. |
| 8 | **Wasted bits × side channels.** | Wasted bits apply in the subframe domain, *after* the side-channel `+1`. `bps_eff = frame_bps + side_extra - w`. Since `PCM` stores the post-shift value, the discarded low bits are zero by construction. I am confident in this; it is exercised by `subset/14` and `faulty/09` `[verified]`. |
| 9 | **Channel-assignment extra bit.** Code 8 → ch1 is side; code **9 → ch0 is side**; code 10 → ch1 is side. Easy to get backwards. | Taken directly from `read_frame_()`; encoded once in `side_extra()`. |
| 10 | **Declared blocksize > remaining samples**, or STREAMINFO `total_samples` wrong (`faulty/05`). | Irrelevant: we never consult `total_samples` and never decide where a frame ends from sample counts. |
| 11 | **Blocksize 65535** (`uncommon/08`) and **65536** (`faulty/08`). | 65536 is expressible in the frame header but rejected by the reference decoder. Our parser must **accept** it (buffers sized 65536) so it does not fall back. `[verified]` present. |
| 12 | **Partition order 15** (`uncommon/09`). | Works; expensive (§6.3). Validity tests in §2.6 are applied identically to the reference's. |
| 13 | Sample-size or sample-rate code 0 with **no STREAMINFO**. | Would be unparseable. Does not occur: `uncommon/10`, `/11`, `faulty/06` all declare their own codes `[verified]`. If it did ⇒ opaque run. |
| 14 | **STREAMINFO lies** about bps (`faulty/03`) and the frames use code 0. | We would parse with the wrong width; the subframe parse or CRC-16 fails ⇒ opaque run. Does not occur in the corpus. |
| 15 | **Mid-stream changes** of sample rate / channels / bit depth (`uncommon/01..04`). | No stream-level assumption anywhere: every `GEOM` record is self-describing. All four parse `[verified]`. |
| 16 | Metadata: missing / duplicate / out-of-order STREAMINFO, type 127, wrong block length. | Metadata is byte-framed and copied verbatim; STREAMINFO is consulted only as a fallback width source. Bad length ⇒ `S_METADATA` codec 0 (opaque). `faulty/06,07,10,11` `[verified]`. |
| 17 | A literal `"fLaC"` inside leading junk. | We take the first occurrence in the first 64 KiB. If the metadata walk then fails to reach a parseable frame, the region splitter falls back (§3.5 step 4) and, in the worst case, the whole file becomes one opaque run. Lossless, zero gain. |
| 18 | **Ogg-FLAC** (`OggS`-framed). | Out of scope for R0: no `"fLaC"` at the start and no frame chain ⇒ whole file becomes one opaque run. Lossless, zero gain. Worth a note in the README. |
| 19 | `>>` on a negative `int64_t` is implementation-defined in C. | Assert at build time (`static_assert((int64_t)-1 >> 1 == (int64_t)-1)`); gcc/clang guarantee arithmetic shift. |
| 20 | Reference `FLAC__lpc_restore_signal` narrow path uses wrapping 32-bit arithmetic. | Non-issue for byte-exactness (§0). Only affects how faithful the `PCM` stream is to a reference decode — which nothing checks. |
| 21 | A residual that does not fit the reference reader's `u ≤ UINT32_MAX` limit, or does not fit the declared escape width. | Emitter checks both; failure ⇒ opaque run. Cannot arise from a well-formed parse. |
| 22 | Reserved code points: blocksize code 0, sample-rate code 15, sample-size code 3, channel code 11–15, subframe type 2–7 / 13–31, residual method 2–3, qlp precision field 15, negative qlp shift. | All checked; any ⇒ opaque run. None occur `[verified]`. |

**What I am *not* claiming:** I have not proved the recipe can express every construct a
*future* encoder might emit. I have verified it expresses everything in 91 files covering
the documented edge cases, and I have arranged for everything else to degrade to `store`.

---

## 8. Verbatim fallback

**Granularity.** A record, i.e. one frame — or, more generally, one *opaque byte run* of
arbitrary length. Making the fallback a byte run rather than a "frame" is deliberate: it
also covers mid-stream garbage, a frame truncated at EOF, and resynchronisation after a
corrupt region, with no extra mechanism.

**Cost when unused: 1 bit per frame** — the `kind` bit at the head of every `GEOM` record
(§4.1). Under R1's adaptive coder a stream with no fallbacks costs well under 0.01 bits per
frame for it. That satisfies the "~1 bit/frame when unused" requirement.

**Trigger.** Any of: a validity check in §2 fails; `c->fallback` is armed by a `derive_*`
mismatch (CRC-8, CRC-16, padding, subframe pad bit); the re-emission byte-compare in §5.8
fails; the emitter cannot represent a recomputed residual (hole 21).

**Encoder procedure.**
1. `recio_mark` all four writers.
2. Attempt `flac_frame(DIR_READ)` at the cursor, then verify (§5.8).
3. On success, commit and advance.
4. On failure, `recio_rewind`, then scan forward from `cursor + 1` for the smallest offset
   `q` at which a frame parses *and* verifies. Only offsets satisfying the cheap sync test
   (`b[q] == 0xFF && (b[q+1] >> 1) == 0x7C`) need a full attempt, so the scan is a memchr
   plus a handful of parses, not a parse per byte. Emit `kind = OPAQUE`,
   `run_length = q - cursor`, push those bytes to `VERB`, set `cursor = q`.
5. If no such `q` exists before EOF, emit one final `OPAQUE` run to EOF (or leave the
   bytes to `S_TRAILER` if no record has been emitted yet in this region).

**Decoder procedure.** Read `kind`. If `OPAQUE`, read `run_length` and copy that many bytes
from `VERB` straight to the output. No FLAC knowledge is involved and the `PCM` cursor does
not move.

**PCM model continuity.** An opaque run contributes no samples. The `PCM` codec's model
state is **reset** at an opaque run (from R1, when there is state to reset). Rationale: an
opaque run is by definition a region we failed to understand, so we have no trustworthy
samples to continue a predictor with. At the PLAN's ≤1 % fallback ceiling the ratio cost is
negligible; above that ceiling the headline number is void anyway (PLAN §2.6).

**Reported metric.** The encoder counts opaque records and opaque bytes and reports both.
A high rate means the parser is weak, not that the format is fine — the auditor owns this
number.

---

## 9. Checklist for `codec-engineer`

Things that are easy to get wrong and that I will review for:

1. `int64_t` everywhere for samples, predictor accumulation, and residuals. No `int32_t`.
2. Buffers sized for blocksize **65536** and 8 channels.
3. `side_extra`: code 8 → ch1, code **9 → ch0**, code 10 → ch1.
4. `bps_eff = frame_bps + side_extra - wasted`; `PCM` stores the post-shift value.
5. CRC-8 and CRC-16 updated in the byte path of `bitio`, once, shared by both directions;
   CRC-16 starts at the `0xFF` sync byte, CRC-8 covers only the header bytes before it.
6. `recio_mark` / `recio_rewind` restore model state, not just position — designed in now.
7. Exactly one `predict()`. Exactly one `sig_xfer()`. Exactly one of each `flac_*`.
8. The only direction tests in the codebase are inside the §5.2 primitives plus
   `sig_pre` / `sig_post`. Grep for `DIR_READ` / `DIR_WRITE`: every hit must be in one of
   those.
9. `GEOM` before `PCM` before `CODE`, always — R4 depends on it.
10. Do not assert `blocksize <= 65535`; do not assert canonical UTF-8; do not assert the
    reserved header bits are zero (they are carried).
