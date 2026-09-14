# PLAN.md — `flacz`: byte-exact lossless recompression of FLAC files

**Author:** project manager (Claude Opus 5)
**Date:** 2026-09-14
**Project dir:** `flacz/`
**Deliverable:** a real CLI, `flacz c in.flac out.flz` / `flacz d out.flz back.flac`, where
`back.flac` is **byte-for-byte identical** to `in.flac` and `out.flz` is meaningfully smaller.

---

## 1. The problem

### 1.1 Format and corner

**Format: FLAC** (Free Lossless Audio Codec).
**Corner: recompressing an existing `.flac` file into a smaller container that restores the
original `.flac` byte-for-byte.**

Not "compress WAV better than FLAC" — that is the crowded corner. The corner here is the
*file you actually have*. People do not have WAVs; they have FLAC libraries. A tool that
makes an existing FLAC library ~10% smaller and gives every original file back bit-identically
(so checksums, tags, EAC/CUE logs, and rip verification all still match) is a thing people
could use today.

### 1.2 Why the audience is broad and non-specialist

FLAC is the default lossless distribution and archival format for consumer music:
Bandcamp, Qobuz, and Tidal deliver FLAC; Deezer and Amazon Music HD use it; it is natively
supported by Android, Windows 10+, VLC, foobar2000, and essentially every Linux
distribution; it is the near-universal output of CD ripping (EAC, dBpoweramp, whipper,
abcde) and the standard format for music archives and lossless torrent communities.
It is also an IETF standard (RFC 9639, 2024). Its audience is "people with a music
collection", not codec researchers. Whole-library storage is a real, everyday cost.

### 1.3 The competitive landscape — checked specifically, by name

Two distinct questions must be asked, and the honest answers are different.

#### (a) Who competes at *this corner* — making an existing `.flac` smaller with exact restore?

Effectively **nobody**. I verified this by measurement rather than assumption.

Running general-purpose compressors over real `.flac` files from the IETF CELLAR FLAC
testbench (12 files, 6,051,651 bytes of `.flac`):

| Tool over the `.flac` file | Result | Δ vs original |
|---|---:|---:|
| `xz -9e` | 5,963,580 | **−1.46 %** |

That −1.46 % is the entire current state of the art for "shrink this FLAC and get it back
exactly". FLAC's payload is Rice-coded residual — already near-incompressible to an LZ or
context-mixing byte model. `precomp`-style recompressors do not apply: FLAC is not a
deflate stream. There is no shipping FLAC recompressor.

The `xz` number is not my real bar, though — beating it is trivial and would be a strawman.
The honest bar is the *reachable* one: what the decoded PCM could be compressed to by the
best modelling that exists. That is question (b).

#### (b) Who competes at lossless *audio modelling* — the real bar

This is a mature, heavily defended field, and I checked every codec the brief names.
Numbers below are **SAC's published head-to-head table** (`slmdev/sac` README), on the
standard 16-file 44.1 kHz stereo corpus, in **bits per sample — lower is better**:

| Codec | Params | Source | Mean bps | vs FLAC |
|---|---|---|---:|---:|
| **Sac v0.7.18** | `--best` | open | **8.303** | −11.0 % |
| **OptimFROG v5.100** | `--preset max` | closed | 8.493 | −9.0 % |
| paq8px_v214 | `-6` | open | 8.530 | −8.6 % |
| MP4ALS RM23 | `-b -p -z3` | open | 8.718 | −6.6 % |
| **Monkey's Audio v10.44** | `-c5000` (Insane) | open | 8.817 | −5.5 % |
| **FLAC v1.5.0** | `-8pe -P0` | open | 9.330 | — |

**WavPack** is not in that table, so I measured it myself. On my 12-file sample,
`wavpack`-class modelling of the decoded PCM lands at **−8.10 %** versus the original
`.flac` — between MAC and OptimFROG, consistent with its published standing.

What I can actually run here, and what I cannot:

| Codec | Status in this environment |
|---|---|
| FLAC (reference) | ✅ buildable (`xiph/flac`) + ffmpeg 7.0.2 encoder |
| WavPack | ✅ buildable (`dbry/WavPack`) + ffmpeg encoder |
| Monkey's Audio | ✅ buildable (`fernandotcl/monkeys-audio`); ffmpeg decodes APE |
| **Sac** | ✅ buildable (`slmdev/sac`) — the *strongest* entry in the table |
| OptimFROG | ❌ **unobtainable.** Closed source, binary-only; `losslessaudio.org` is blocked by this session's egress policy. |

I will not pretend otherwise about OptimFROG. It is the only named competitor I cannot run.
This is acceptable because **Sac beats OptimFROG** (8.303 vs 8.493) and Sac *is* runnable —
so my locally-verifiable ceiling is *stronger* than OptimFROG, not weaker. Any claim I make
about OptimFROG will be cited to the published table above and labelled as such, never
presented as something I measured.

#### (c) Verdict: is the corner already dominated?

No. The two questions have different answers, and that asymmetry *is* the opportunity:

- Modelling (b) is dominated — Sac/OptimFROG are excellent and I will not beat them.
- The corner (a) is **empty**. Nobody has connected the two. The ~10 % that Sac and
  OptimFROG extract over FLAC is, today, simply unavailable to anyone holding a `.flac`
  file, because taking it means destroying the file.

`flacz` closes that specific connection: model the PCM well, *and* store enough to rebuild
the original FLAC bitstream exactly.

### 1.4 Verified headroom

Two independent confirmations that the gap is real, not assumed:

1. **Published:** FLAC −8 → Sac = **−11.0 %**; → OptimFROG = −9.0 %; → MAC Insane = −5.5 %.
2. **Measured by me here:** re-encoding the decoded PCM of real testbench FLACs with a
   merely *mid-tier* coder (ffmpeg's wavpack) already yields **−8.10 %**, while `xz` on the
   `.flac` itself yields −1.46 %.

So: ~1.5 % is what exists today at this corner; ~8–11 % is demonstrably reachable. The
difference is the headroom, and it is large enough that several rounds of iteration have
something real to close.

The cost side is the "recipe" — the FLAC coding decisions needed for exact re-emission.
Its size is the central engineering risk and the thing rounds must drive down. First-order
estimate: a few hundred bits per frame against ~50,000 bits of payload, i.e. well under
1 %. If it proves larger, that is a finding to report, not to hide.

### 1.5 Why exact FLAC reconstruction is tractable (and why I rejected the PNG analogue)

I considered the exactly analogous image project — recompress PNG, restore byte-exactly —
and rejected it for a concrete structural reason. To rebuild a deflate stream you must
reproduce the encoder's LZ77 parse, which is *not* compactly derivable from the data;
that is why `preflate` is thousands of lines of inference and correction. FLAC has no such
problem: a FLAC subframe is **fully parameterized** (type, order, qlp precision, shift,
coefficients, Rice partition order and parameters). Given those parameters and the original
samples, the residual and therefore every emitted byte is **uniquely determined**. Parsing
recovers the parameters exactly; re-emission is deterministic. Exactness is available *by
construction*, which is what makes this buildable in the rounds available.

### 1.6 Learned components

None required, and by default none used. The predictor is classical adaptive signal
processing — cascaded NLMS / sign-sign LMS with bias correction — which *adapts online
during the single coding pass* and has no training phase whatsoever. Nothing is trained
offline, nothing ships a model file, no GPU is involved. This is the same class of
machinery Monkey's Audio and OptimFROG use, and it is what makes the ~10 % reachable at
ordinary CPU speed. Any parameter tuning is a small offline search over the corpus
producing a handful of constants, run in minutes on 4 CPU cores.

---

## 2. Success, improvement, and the gates

### 2.1 Losslessness — the absolute gate

**Non-negotiable and independently enforced.** `bench/verify.sh` (adapted from the attached
prior-project script; copied in as the first action of this project) is the sole authority.
It never consults what `flacz` says about itself: it stages a pristine copy the compressor
is never pointed at, compresses a *separate* working copy, then builds a **fresh empty
directory containing only the `.flz` file and a copy of the binary**, `cd`s there, and
decompresses as its own process — so nothing can leak through a side file, a cached
dictionary, or any path outside that directory. It then compares `cmp` **and** `sha256sum`
against the pristine copy.

Adaptations from the original: binary `pgnz` → `flacz`, extension `.pgnz` → `.flz`, plus
(a) tolerance for spaces in filenames, since the corpus uses them, and (b) a per-file
ratio column so the same run produces the ratio table, removing any chance of measuring
ratio on a run that differs from the one that proved losslessness.

- **Gate: 100 % PASS on every file in the corpus. Zero exceptions.** A round that fails one
  file is a failed round regardless of its ratio. Ratio numbers from a run with any FAIL
  are void and will not be reported as results.

### 2.2 Corpora — and an honesty control

Two corpora, deliberately separated, because mixing them would let me inflate results:

- **CORPUS-STRESS** — the IETF CELLAR FLAC testbench as-is (`subset/`, `uncommon/`,
  `faulty/`; 91 files, ~260 MB, CC0). Correctness only. Includes variable blocksize,
  32nd-order predictors, 8-channel, 192/384/768 kHz, 8/12/15/20/24/32-bit, Rice escape
  partitions, partition order 15, wasted bits, giant metadata blocks, streams with junk
  before the first frame, files from **non-reference encoders** (Flake, CUETools.Flake),
  and deliberately corrupt files. This is the robustness gate.

- **CORPUS-NATURAL** — the decoded PCM of the clean subset files, **re-encoded with
  reference `flac -8`**. These are what real-world FLAC files actually look like.
  **All headline ratio claims come from this corpus only.**

The reason for the split is a trap I want to stay out of: several stress files are
*deliberately badly encoded* (e.g. "only verbatim subframes", "all fixed orders"). Beating
those is easy and meaningless — my own probe re-encoded one of them 13 % smaller with
nothing but ffmpeg. Reporting that as a result would be a strawman. CORPUS-NATURAL removes
the temptation structurally. The auditor's standing orders include checking that no headline
number ever comes from CORPUS-STRESS.

### 2.3 The ratio metric

Primary metric, reported as a single number over the whole of CORPUS-NATURAL:

```
saving = 1 − (Σ compressed .flz bytes) / (Σ original .flac bytes)
```

Aggregate over summed bytes, never a mean of per-file percentages (that would over-weight
tiny files). Reported alongside it, always:

- the **recipe overhead** in % of output — the price of exactness, reported separately so
  it can never be quietly buried in the total;
- **bits per sample** of the PCM layer alone, so my modelling can be placed directly on the
  Sac/OptimFROG/MAC/FLAC table in §1.3 — this is the number that says whether my coder is
  actually competitive or whether I am only winning because the corner was empty.

**Targets:**

| | saving vs input `.flac` |
|---|---:|
| Floor (else the project failed) | ≥ 2 % — must clear `xz`'s 1.46 % by a clear margin |
| Target | **≥ 7 %** |
| Stretch | ≥ 9.5 % (OptimFROG-class modelling, minus recipe cost) |

"Improvement" round-over-round means: saving on CORPUS-NATURAL goes up, with 100 % verify
PASS on **both** corpora, at or above the speed gate. Any two of three is not an improvement.

### 2.4 The speed gate

A compressor too slow to run is not a usable result. Sac's `--best` needs **4 h 37 m** for
51 MB; that is a research artifact, not a tool. Measured single-threaded on this box
(4-core Xeon @ 2.80 GHz), throughput in **bytes of original `.flac` per second**:

- **Decompress ≥ 1.0 MB/s** — hard gate. (≈ 6× realtime for CD audio; a 60-minute album
  restores in well under a minute.)
- **Compress ≥ 0.4 MB/s** — hard gate. (A 500-album library re-packs overnight.)
- Peak RSS ≤ 1 GB.

A round that breaks a speed gate must either be reverted or given an explicit speed tier;
it does not get to claim the ratio.

### 2.5 Architectural constraint — one shared walk per structural element

**Non-negotiable. Enforced at review time, not discovered at debug time.**

Every structural element is implemented as **exactly one function, parameterized by
direction**, called once to compress and once to decompress. There is no second,
hand-written mirror implementation of anything. A single walk over the data carries one
copy of the context computation and one copy of the model-update logic.

The primitive:

```c
typedef enum { DIR_READ, DIR_WRITE } dir_t;

/* Transfers one field in whichever direction we are walking. */
static inline void xfer_u(bitio *b, dir_t d, uint32_t *v, int nbits) {
    if (d == DIR_READ) *v = bits_read(b, nbits);
    else               bits_write(b, *v, nbits);
}
```

Every element above it follows the same shape — `flac_frame_header(ctx, d, ...)`,
`flac_subframe(ctx, d, ...)`, `flac_residual(ctx, d, ...)`, `rc_bit(rc, d, &bit, &prob)`,
`pcm_block(ctx, d, samples, n)`. In `pcm_block` the predictor state, the context
derivation, and the model update are written **once**; only the single innermost
symbol-transfer call branches on direction. Encoder and decoder therefore cannot drift
apart, because there is no second copy to drift.

**This is a design-time rejection criterion.** Any proposal that needs two separately
maintained encode/decode implementations is rejected before it is built. The auditor's
standing orders include grepping for mirrored logic, and any direction-dependent branch
outside the sanctioned primitives is a defect to be reported even if every test passes.

### 2.6 Belt and braces: encode-time self-verification

Independently of the architecture, the encoder re-emits every frame it has parsed and
compares against the original bytes *while compressing*. On any mismatch the frame is
stored **verbatim** with a flag. Consequences:

- losslessness holds on *any* input — corrupt streams, non-FLAC data, trailing junk;
- a parser bug costs ratio, never correctness;
- the verbatim-fallback rate is a first-class reported metric.

That last point matters, and the auditor owns it: a high fallback rate is a silent way to
"pass" by degenerating into `store`. **Fallback rate is reported every round**, and any
headline ratio is void if fallback exceeds 1 % of frames on CORPUS-NATURAL.

---

## 3. Delegation structure

Four subagents in `.claude/agents/`, each narrow, each with a model chosen for its job.

### 3.1 `codec-architect` — model: **opus** (strong)
**Responsibility.** Owns the `.flz` container layout, the recipe encoding, and the
predictor/entropy-coder architecture. Produces written specs precise enough to implement
against; does not write production code. Holds the §2.5 shared-walk constraint as a
rejection criterion at design time.
**Why opus.** This is the irreversible-decision role. A bad container or a recipe design
that cannot express some legal FLAC construct is not a bug you patch — it is a rewrite, and
it surfaces late, as a verify failure on an exotic file. Format design also demands holding
the whole of RFC 9639's edge cases in view at once. Strongest model, smallest volume of
output.

### 3.2 `codec-engineer` — model: **sonnet** (mid-tier)
**Responsibility.** Implements the architect's specs in C: bit I/O, FLAC parse/emit walk,
range coder, NLMS cascade, CLI. Makes it build clean and pass verify. Does not redesign the
format; if a spec cannot be implemented as written, it reports back rather than improvising.
**Why sonnet.** High-volume, well-specified implementation against a fixed design — the
work is careful C, not judgement. Mid-tier is the right cost/throughput point, and the
architect (design) and auditor (correctness) bracket it on both sides.

### 3.3 `bench-runner` — model: **haiku** (cheap)
**Responsibility.** **Measurement only.** Runs `bench/verify.sh` and the ratio/speed
harness, builds and runs reference codecs (flac, wavpack, MAC, Sac), emits tables of
numbers. Explicitly forbidden from editing anything under `src/`, from tuning parameters,
and from interpreting results — it reports what the numbers are, not what they mean.
**Why haiku.** Running scripts and tabulating output needs no reasoning depth, and it runs
many times per round. Cheap and fast is exactly right. The hard read-only boundary is what
makes a cheap model safe here: it cannot damage the codec, and a benchmark runner that
cannot touch the thing it measures cannot accidentally launder a bad result.

### 3.4 `adversarial-auditor` — model: **opus** (strong)
**Responsibility.** Standing assumption: **any suspiciously good result is wrong, and its
job is to find out why.** Each round it independently attacks the latest result. Its
permanent checklist:
- Is `verify.sh` genuinely independent, or has something made it weaker (does the fresh
  directory still contain only the `.flz` and the binary)?
- Any side channel — temp file, cached dictionary, absolute path, `/tmp` state, env var,
  or original-file read — that lets decode see data the `.flz` does not carry?
- Is the ratio computed over the same files verify passed, with no file quietly skipped?
- Verbatim-fallback rate — is the "win" actually degeneration into `store`?
- Did a headline number come from CORPUS-STRESS instead of CORPUS-NATURAL?
- Any mirrored encode/decode logic, or any direction-dependent branch outside the
  sanctioned primitives (§2.5)?
- Does the claimed bps put us somewhere implausible on the §1.3 table?
It reports findings; it does not fix them.
**Why opus.** Adversarial reasoning against one's own team is the hardest cognitive task
here — the failure modes are subtle, plausible-looking, and self-serving, and a weaker model
tends to confirm rather than break. Strong model, and deliberately *separate* from the
engineer so it has no stake in the result it is attacking.

---

## 4. Rounds and definition of done

**Six rounds (R0–R5).** Every round: one paragraph in `LOG.md` *before* (what and why), and
the measurement *after*. The auditor runs every round, including — especially — good ones.

| Round | Goal | Exit criterion |
|---|---|---|
| **R0** | Scaffold, `.flz` container, FLAC parse/emit shared walk, verbatim fallback, PCM stored raw. | **100 % verify PASS on both corpora.** Ratio will be *negative*; that is expected and fine. Correctness first, always. |
| **R1** | Baseline PCM layer: fixed-order predictors + adaptive Rice. Recipe compression. | 100 % PASS; saving > 0 %; speed gates met. |
| **R2** | Cascaded NLMS (orders ~32/256/16) + bias correction + stereo decorrelation. | 100 % PASS; saving ≥ 4 %. |
| **R3** | Strong residual entropy coding: adaptive binary range coder, SSE, context mixing. | 100 % PASS; saving ≥ 7 % (**target met**). |
| **R4** | Recipe-overhead reduction (predict FLAC params from context) and speed work. | 100 % PASS; saving ≥ 8 %; both speed gates comfortably clear. |
| **R5** | Audit-driven hardening; head-to-head against flac/wavpack/MAC/Sac on CORPUS-NATURAL; final numbers. | 100 % PASS; no unresolved auditor finding; `SUMMARY.md`. |

If a round's idea does not pay, it is reverted and the log says so with the number that
killed it. A dead end gets written down as a dead end — I will decide how to proceed and
record the decision rather than quietly dropping it.

### Done means, all simultaneously:

1. **100 % PASS** from `bench/verify.sh` on CORPUS-STRESS *and* CORPUS-NATURAL — every
   file, both corpora, independently verified, exit code and stdout of `flacz` ignored.
2. **≥ 7 % saving** on CORPUS-NATURAL versus the input `.flac` bytes (floor: ≥ 2 %).
3. Both **speed gates** met: decompress ≥ 1.0 MB/s, compress ≥ 0.4 MB/s, RSS ≤ 1 GB.
4. **Verbatim fallback ≤ 1 %** of frames on CORPUS-NATURAL.
5. A **head-to-head table** placing the PCM layer's bps against FLAC, WavPack, Monkey's
   Audio and Sac as actually run here — with OptimFROG cited from published figures and
   explicitly labelled as not locally reproduced.
6. **No unresolved finding** from `adversarial-auditor`.
7. A usable CLI: `flacz c` / `flacz d`, builds from `make`, with a README.

Failing to hit 7 % while meeting 1, 3, 4, 6 and 7 is a partial success and will be reported
as exactly that — a working, honest tool with a smaller win — not dressed up as the target.
