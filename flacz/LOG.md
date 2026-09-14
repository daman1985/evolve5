# LOG.md — flacz

Running log. One paragraph *before* each round saying what I am about to try and
why; the measurement *after*. Dead ends get written down as dead ends.

---

## Round 0 — scaffold, container, exact FLAC re-emission, PCM stored raw

**Before.** The single riskiest assumption in this whole project is the one everything
else rests on: that a FLAC frame can be parsed into a compact "recipe" and then re-emitted
**byte-for-byte** from that recipe plus the decoded samples. If that is false, or true only
for reference-encoded files, the project has no product — so I am spending the entire first
round proving it, and deliberately *not* compressing anything. R0 stores the PCM completely
raw. The output will be substantially **larger** than the input `.flac`, and that is the
expected and correct outcome for this round; ratio work starts in R1. What R0 must
establish is a 100% PASS from `bench/verify.sh` across the whole stress corpus — including
the files the reference encoder never produces: variable blocksize in both the modern and
the old Flake signalling, 32nd-order predictors, Rice escape partitions, partition order
15, wasted bits, 8/12/15/20/24/32-bit depths, 8 channels, 768 kHz, giant metadata blocks,
streams that begin with unparsable junk, and the deliberately corrupt `faulty/` set. I am
also building in the safety net from the start rather than retrofitting it: the encoder
re-emits every frame it parses and compares against the original bytes *while compressing*,
and stores the frame verbatim on any mismatch. That makes losslessness hold on arbitrary
input by construction, turns every parser bug into a ratio cost instead of a correctness
bug, and gives me a fallback-rate metric that tells me exactly how good the parser really
is — a number I would otherwise have to guess at. Architecture is delegated to
`codec-architect` (opus) because the container and recipe design are the decisions that are
expensive to get wrong, implementation to `codec-engineer` (sonnet), measurement to
`bench-runner` (haiku), and `adversarial-auditor` (opus) audits the result even though a
round that produces a *negative* saving is the one least likely to be hiding a flattering
lie.

**After.** _(pending)_
