# GEMM Engine v1: Specification

---

## 1. Purpose and scope

v1 computes **C = A · B** for signed int8 matrices with int32 results. It uses one fixed 16×16 weight-stationary
systolic array: a single `systolic` instance with M = 16. Its inputs and outputs are split into 8-lane halves
(banks, skew and timing work per half). It tiles GEMMs of any (supported) size onto that array.

| In scope (v1) | Out of scope (v1) |
|---|---|
| Tiled GEMM: A (M×K) · B (K×N) → C (M×N), any M, K, N from 1 to 65 536 (edge tiles padded in hardware) | Runtime reconfiguration of cores (independent / N-split / K-split): **v2** |
| int8 × int8 → int32 accumulate (fixed) | Floating point, int4, mixed precision, zero points |
| On-chip SRAM buffers (behavioral 1R1W models), fed by A/B input streams | DRAM, DMA, host bus (AXI/APB): later |
| Command-level execution units + descriptor sequencer | Bias, requantization, activation functions |
| Self-checking testbench against a reference model | Synthesis / PPA (planned after v1 is functional) |

**v2 plan:** v2 builds the same array from four 8×8 instances of the same `systolic`/`pe` RTL, with muxes at the
core boundaries, so the cores can run independently or be regrouped. v1 and v2 share that RTL, so the cost of that flexibility (area, timing,
control complexity, verification effort) can be **measured** against what it buys (utilization on small or odd
shapes). See §12.

---

## 2. Terms

| Term | Meaning |
|---|---|
| M, K, N | GEMM dimensions: A is M×K, B is K×N, C is M×N |
| S | Half-width = 8: lanes per bank and per skew triangle (v2: core size) |
| T | Logical array size = 2·S = 16 |
| R | Rows of A streamed per weight tile ("pass length"). **Fixed at 16 in v1** |
| Tile | 16×16 block (smaller at the edges). A_rk, B_kn, C_rn with r = 0..⌈M/16⌉−1, k = 0..⌈K/16⌉−1, n = 0..⌈N/16⌉−1. Elsewhere M/16 etc. are shorthand for these ceilings |
| Pass | One weight tile B_kn resident while the 16 rows of A_rk stream through: 16 cycles |
| Block | One C_rn. It takes K/16 passes to complete |
| Quadrant | 8×8 corner of the 16×16 array: rows 0–7 / 8–15 × columns 0–7 / 8–15. Used only to describe timing; no hierarchy in v1 |

---

## 3. Data formats

| Quantity | Format |
|---|---|
| A, B elements | signed int8 |
| Psum inside the array (every PE) | 20 bits signed (`PSUM_W`, sized for the full 16-deep column) |
| Accumulator, C output | signed int32 |

- **Fixed widths.** v1 supports only int8 → int32; there are no top-level width parameters. Inside the RTL the
  widths are **named localparams**. The psum widths are derived from the input width, not written as literals,
  so int4 remains a one-line experiment for later PPA work.
- **Signed × signed** (symmetric quantization). Unsigned activations with zero points are out of scope.
- **Psum widths.** The worst case for a D-deep column is D · (−128)² = D · 2^14. Holding that as a signed value
  takes 2·NA + log2(D) bits (NA = 8): 20 bits for D = 16. Rows 0–7 would need only 19 bits, but one width is used
  everywhere. Synthesis will **not** trim the unused bit: that needs value-range analysis across a chain of registered
  adders, which tools don't do. The accepted cost is about 128 extra flops plus one adder bit in each of 128 PEs.
- **Overflow.** The final |C| is at most K · 2^14, which fits in int32 for **K ≤ 131 071**. The accumulator wraps
  in two's complement, with no saturation and no overflow flag. The descriptor's 16-bit K field (at most
  65 536, §9.2) stays below this bound, so overflow can't occur.

---

## 4. Architecture overview

```
                          B stream in (DVS, 16 × int8 per beat)
                     ┌───────────┴───────────┐
              B bank L (N 0-7)        B bank R (N 8-15)    <- weight reads; bank R read 8 cycles later
                     │ 0→7 skew              │ 0→7 skew
                     ▼                       ▼
                 ┌──────────────────────────────────────┐
 A bank T  ─0→7─►│  rows 0-7                             │
 (K 0-7)    skew │                                       │
                 │      16×16 weight-stationary array    │
 A bank B  ─0→7─►│  rows 8-15     (one `systolic`, M=16) │
 (K 8-15)   skew │                                       │
 (read 8 later)  │  cols 0-7                 cols 8-15   │
                 └──────────┬─────────────────────┬──────┘
                            │ 7→0 de-skew         │ 7→0 de-skew
                            ▼                     ▼
                 ACC bank L (C 0-7)      ACC bank R (C 8-15)   <- read-modify-write; bank R 8 cycles later
                            │                     │
                            ▼                     ▼
                 C out L (cols 0-7)      C out R (cols 8-15)   <- two half-row streams, valid only (§10)

 A stream in (DVS, 16 × int8 per beat) writes A bank T (lanes 0-7) and A bank B (lanes 8-15).
 Top controller (descriptor → pass commands) drives the weight, activation and output controllers (§9).
```

---

## 5. Compute array

### 5.1 Array
One instance of the existing weight-stationary array (`pe.sv`, `systolic.sv`) with M = 16, NA = 8, NPIN = `PSUM_W`:
- Each PE has **double-buffered weights**. The next tile shifts into the idle buffer while the current tile computes.
- `a_first` (swap to the new weights) travels with the activations, so the swap follows the diagonal wavefront.
  `w_latch` ends the weight load.
- PE: `p_out = p_in + a · w`, registered. Activations move right and psums and weights move down, one PE per cycle.

### 5.2 Connections

| Path | Lanes 0–7 | Lanes 8–15 |
|---|---|---|
| Activations in (left edge, rows) | A bank T (K 0–7) | A bank B (K 8–15) |
| Weights in (top edge, columns) | B bank L (N 0–7) | B bank R (N 8–15) |
| Psum in (`p`, top edge) | 0 (no bias in v1) | 0 (no bias in v1) |
| Psum out (bottom edge, columns) | ACC bank L | ACC bank R |

- **Activation reuse (left → right):** each row's activation passes all 16 columns.
- **K reduction (top → bottom):** each column sums all 16 rows (K 0–15) on the way down.
- **Weight chain:** each column's weight shift chain is **16 deep**. A full weight-tile load takes **16 cycles**.

### 5.3 Timing offsets
Row j's activation must enter j cycles after row 0's, and column j's weights j cycles after column 0's. Each 8-lane
half provides 0–7 with its own skew triangle (§6); the upper half's extra 8 cycles come from read timing:
- Rows 8–15 activations (A bank B) are read **8 cycles after** rows 0–7 (A bank T).
- Columns 8–15 weights (B bank R) are read **8 cycles after** columns 0–7 (B bank L).
- Columns 8–15 outputs arrive **8 cycles after** columns 0–7. ACC bank R and C out R run 8 cycles behind bank L.

All of these offsets are implemented as **read and access timing on separate banks**, not as delay registers (§6).

### 5.4 Latency
From an A row being read to its 16-wide psum row reaching the accumulators takes about 2T − 1 = **31 cycles**,
plus the SRAM read latency and the accumulator pipeline. The exact figure is confirmed by the RTL and recorded here.

---

## 6. Skew and de-skew

| Location | Structure | Size |
|---|---|---|
| Activation input, rows 0–7 and 8–15 | one 0→7 triangle per half (lane j delayed j cycles) | 2 × 28 × 8 bits |
| Weight input, columns 0–7 and 8–15 | one 0→7 triangle per half | 2 × 28 × 8 bits |
| Output, columns 0–7 and 8–15 | one de-skew triangle per half (column j delayed 7 − j cycles) | 2 × 28 × 20 bits |
| Offsets between halves (8 cycles) | read/access timing on width-split banks | 0 flops |

**Why a triangle per half, not 0→15:** a 0→15 triangle or 0→7 triangles plus 8-deep delay lines both come to 120
words per path. Splitting each memory into two width halves (8 lanes each) moves the 8-cycle offset into read
timing, and saves 64 words per path. The cost is duplicated row decoders and control in each bank. That cost is
modest because the split is by width, not depth.

**Considered, not adopted:**
- Finer splits (4 lanes per bank): each extra SRAM bank's fixed periphery costs more than the flops saved.
- Per-column output FIFOs (TPU style, no output de-skew): at depth 16 they would be flops, about 8k (roughly the
  same as the PE array). Worth it only at much larger depths. Candidate for the v1/v2 comparison.

---

## 7. Memories

All buffers are instances of `rtl/ram_1r1w.sv`: one read and one write port, 1-cycle synchronous read, per-element
write mask, no reset. Regressions run with `RDW_X=1` to show the design never depends on a read and write to the
same address in one cycle.

| Buffer | Banks | Word | Depth | Notes |
|---|---|---|---|---|
| A (activations) | 2: T = K lanes 0–7, B = K lanes 8–15 | 8 × int8 = 64 b | ≥ 24, exact [OPEN] | ring buffer; one word = 8 K-values of one A row |
| B (weights) | 2: L = N lanes 0–7, R = N lanes 8–15 | 8 × int8 = 64 b | ≥ 24, exact [OPEN] | ring buffer; one word = 8 N-values of one B row |
| ACC (accumulator) | 2: L = C cols 0–7, R = C cols 8–15 | 8 × int32 = 256 b | 16 (= R) | 2 × 512 B = **1 KB** |

### 7.1 Bandwidth (steady state, per cycle)

| Path | Bytes/cycle | Notes |
|---|---|---|
| A stream in | 16 B | one A row per beat; A is re-sent for every n (§7.2) |
| B stream in | 16 B | one B row per beat; one tile per pass at full throughput |
| A reads | 16 B | 8 B per bank |
| B reads | 16 B | continuous: one 256-value tile per 16-cycle pass |
| ACC reads | 64 B | every pass except a block's first (32 B per bank) |
| ACC writes | 64 B | every pass except a block's last (32 B per bank) |
| C output | 64 B in bursts | during a block's last pass only (two 32 B half-streams, 8 cycles apart); average 64 / (K/16) B |

### 7.2 Loading inputs
A and B arrive as two input streams (§10), one 16-wide row per beat. A beat is split across the two banks of its
path and written to the same address in both. Loading runs concurrently with compute: the A and B banks are
**ring buffers**, written from the input stream and read by the passes.

- **Stream order = pass order.** Upstream sends tiles in the §8.1 loop order: for each (r, n), A_r0 … A_r,K/16−1
  and B_0n … B_K/16−1,n. The engine consumes the next tile in each stream and never addresses tiles itself. A
  reordered stream gives a wrong C without any error.
- **A is re-sent for every n** (and B for every r). Reuse is handled by the next storage level upstream, not near
  the array, so bank depths don't depend on the GEMM shape. Cost: A input traffic × N/16. Holding the A strip in
  the bank instead (K rows, saving that traffic) is a candidate PPA experiment for later.
- **Whole tile before its load starts.** The skew delay lines run every cycle with no enable, so a weight load or
  an A stream can't pause partway. A pass (and the weight load feeding it) starts only when its whole tile is in
  the bank. That check happens at the pass boundary, the only place stalls are allowed (§9).
- **Minimum depth ≈ 24 rows** (16 + 8, ±1 for read latency). Bank R is read 8 cycles after bank L, so a row slot
  is free for the next tile only once bank R has read it. During one 16-cycle load only about 8 slots free up, so
  the other 8 rows of the next tile need slots that were already free. 24 rows sustains full throughput only if
  upstream delivers each row exactly as its slot frees; every row above 24 absorbs upstream jitter. Two full tiles
  (32) would fully decouple upstream bursts from the passes.
- **Non-power-of-2 depths** are allowed by `ram_1r1w`. Pointer wraparound then needs an explicit compare and reset,
  and tiles may straddle the wrap point.
- **Edge tiles are shorter in the stream.** Upstream sends only real data: a partial B tile is k-size beats, a
  partial A tile is m-size beats. Lanes beyond the real width in a beat (n-size for B, k-size for A) are
  don't-care. The engine pads (§9.3).
- **Data only on the stream.** A beat carries one row and nothing else: no tile or block markers. Tile boundaries
  come from the descriptor: TC knows every tile's size (16, or the low 4 bits of the dimension at an edge), so it
  knows how many rows the next tile needs (§9.5).
- **Pointer ownership:** WC and AC each own their bank's write and read pointers and occupancy, drive the external
  stall (`w_stall`, `a_stall`) when the bank is full, and report **rows available** to TC.

---

## 8. Dataflow

### 8.1 Loop order (k innermost)
The accumulator holds exactly one C block (16×16 int32). Each block must therefore be completed before the next
starts:

```
for r = 0 .. M/16-1
  for n = 0 .. N/16-1
    for k = 0 .. K/16-1
      pass: B_kn resident, stream the 16 rows of A_rk, accumulate into C_rn
```

- Each pass's weights load into the idle buffers **during the previous pass**. A load takes 16 cycles, the same as
  the pass length, so R = 16 is also the **smallest R that is bubble-free**. Only the first pass of a GEMM needs a
  16-cycle preload.
- Each A row strip (A_r0 … A_r,K/16−1) is used once per n: A_rk recurs every K/16 passes. Each B tile is used once
  per r: B_kn recurs every (N/16)·(K/16) passes. Upstream re-sends them each time (§7.2).

### 8.2 Pass types and the accumulator (direct output)
Each valid psum row goes through one datapath: **fetch acc[row] → add the incoming partial → deliver the result.**
The pass type only sets two selects:

| Pass | Fetch acc[row] | Adder's second input | Result goes to |
|---|---|---|---|
| First of a block | no | 0 | acc[row] (write) |
| Middle | yes | fetched value | acc[row] (write) |
| Last of a block | yes | fetched value | **C output** (no write-back) |
| Only pass (K = 16) | no | 0 | **C output** (the accumulator isn't touched) |

- **Hazard rule:** the next fetch of a row comes R = 16 cycles after its previous update. The read → add → write
  pipeline must be **shorter than 16 cycles**, so a row is never read before its previous update is written.
- **Valid tracking:** every psum row carries a valid bit down to the accumulator. Bubbles between passes never
  trigger a fetch, write or output.
- **Considered, not adopted:** draining a finished block through the free read port during the next block's first
  pass. That scheme lets a finished block wait if the output isn't ready. With no output backpressure (§10) it only
  adds cost: an extra write and read per element, a flush pass at the end, and output timing tied to the next block.

### 8.3 Worked example: A 48×48 · B 48×64
3 (r) × 4 (n) × 3 (k) = 36 passes × 16 = 576 cycles of compute (= 48·48·64 MACs / 256 per cycle).

| Pass | Weights | A | ACC fetch | Result |
|---|---|---|---|---|
| 1 | B00 | A00 | no | C00 ← A00·B00 |
| 2 | B10 | A01 | C00 | C00 ← C00 + A01·B10 |
| 3 | B20 | A02 | C00 | **C00 final → output** |
| 4 | B01 | A00 | no | C01 ← A00·B01 |
| … | | | | |
| 34 | B03 | A20 | no | C23 ← A20·B03 |
| 35 | B13 | A21 | C23 | C23 ← C23 + A21·B13 |
| 36 | B23 | A22 | C23 | **C23 final → output** |

### 8.4 Performance model
cycles ≈ 16 · (M/16)(N/16)(K/16) + 16 (first weight preload) + pipeline fill (≈ 31 + SRAM/ACC latency).
For the example: 576 / ≈ 625 ≈ **92%**. Larger GEMMs approach 100%. Milestone 5 measures the RTL against this model.

---

## 9. Control

Two layers. The lower one is built and verified first.

1. **Execution units driven by pass-level commands.** The testbench can issue commands directly, so each unit is
   verified on its own.
2. **Descriptor sequencer.** It walks the §8.1 loops from a GEMM descriptor and issues the same commands. A failing
   GEMM can be debugged by comparing its command stream against the one the testbench would issue.

### 9.1 Controller structure
| Block | Role |
|---|---|
| Top controller (TC) | Descriptor queue, response channel, abort, the §8.1 loop counters and tile sizes. Issues pass commands to WC, AC and OC at pass boundaries, only when both tiles are complete in the banks (§7.2) |
| Weight controller (WC) | Accepts the B stream into banks L/R (owns their pointers, drives `w_stall`). From a pass command: reads one B tile (bank R 8 cycles later), pads it to 16×16 (§9.3), drives `w_latch` |
| Activation controller (AC) | Accepts the A stream into banks T/B (owns their pointers, drives `a_stall`). From a pass command: streams one A tile (bank B 8 cycles later), pads it to 16 rows (§9.3), drives `a_first` |
| Output controller (OC) | Accumulator fetch / add / write and the C output streams, from the delayed pass command. Reports each finished GEMM to TC (`out_ack`) |

- **Command channel:** TC → WC and TC → AC each use a valid/stall handshake. TC keeps sending while the unit doesn't
  stall. These need their own signal names, separate from the external `w_stall` / `a_stall`.
- **Row reporting:** WC and AC each tell TC how many rows their banks hold. TC starts a pass when the B bank holds
  at least the next B tile's k-size rows and the A bank at least the next A tile's m-size rows. The units count
  rows; only TC knows where tiles begin and end.
- **Weights in flight:** W_m active in the PEs, W_m+1 loading into the idle weight buffers, W_m+2 arriving in the
  bank.
- **WC ↔ AC interlock, direct between the units** (one flag per side, both registered):
  AC may start pass m+1 only once W_m+1 is fully loaded (`w_latch` done), and WC
  may start loading W_m+2 only once pass m+1 has started (the `a_first` swap frees the idle buffers). Two signals:
  WC → AC "weights loaded", AC → WC "pass started". TC is not involved, so it can issue `acmd` without waiting.
- **`w_latch` timing:** a single pulse on all rows, timed as in an N×N array (when bank L's last tile row is read).
  It enters column 0 and moves one column per cycle through the PEs, so column j sees it j cycles later, matching
  its weight skew. Columns 8–15 get their j-cycle delay as 8 (bank R read offset) + (j − 8) (skew triangle), so the
  array sees the same per-column timing as a 0→15 triangle. A short K tile still shifts all 16 rows (zeros padded),
  so `w_latch` stays at the end of the full 16-row shift.
- **Pass type to OC:** several passes are in flight, so OC can't use the current command. The pass type reaches OC
  about 31+ cycles later, matched to its psum rows: either as a valid + tag pipeline alongside the array (§8.2) or
  through a small command queue.
- **End of GEMM (OC → TC):** TC sets `gemm_last` on the GEMM's final pass command to OC. When the last C row of
  that pass has left (the C out R row, the last ACC data OC flushes), OC sends `out_ack` (DV, OC → TC, payload =
  the GEMM's ID, carried in the OC command). TC sends the end response only then, not at the last issue. The ack
  carries the ID because TC can accept GEMM N+1 while OC is still finishing GEMM N.

### 9.2 GEMM descriptor (external command)
One command per GEMM: "start a new GEMM of this shape". It carries no addresses: in the push model (§7.2) the
engine never addresses tiles. A, B and C base addresses and strides belong to a future DMA layer upstream (§9.7).

The descriptor arrives on the `cmd` bus (DVS, §10) as {ID, M, K, N}, 52 bits:

| Field | Width | Meaning |
|---|---|---|
| `ID` | 4 b | host-chosen job tag, echoed in every response for this GEMM (§9.6) |
| `M` | 16 b | rows of A and C, in **elements** (not tiles) |
| `K` | 16 b | columns of A / rows of B, in elements |
| `N` | 16 b | columns of B and C, in elements |

- **0 encodes 65 536.** Every dimension is 1 … 65 536, with no invalid value. A dimension of 0 is never meant
  literally, so a 0 field almost always means an unprogrammed descriptor. The accept response flags it (§9.6), and simulation
  also reports it: an `` `ifndef SYNTHESIS `` check issues a `$warning` when a descriptor with a 0 field is
  accepted. No hardware error.
- **Element counts, not tile counts.** Tile count = ⌈D/16⌉ = `D[15:4]` + (`D[3:0]` ≠ 0), or 4096 for D = 0 (so the
  loop counters are 13 bits). The low 4 bits are the edge-tile size for free (§9.3).
- **Overflow:** K ≤ 65 536 keeps |C| ≤ 2^30, inside int32 (§3). The width enforces the bound.
- **M and N:** the engine stores nothing whose size scales with M or N (A and B are streamed, C leaves per block),
  so their limit is only a counter width.

### 9.3 Pass commands (internal)
TC walks the §8.1 loops (counters r, n, k) and issues one pass command per pass. Size fields are 4 bits with
**0 = 16**: full tiles send 0, and the last tile of a dimension sends `D[3:0]` directly.

| To | Fields | Bits | Notes |
|---|---|---|---|
| WC | k-size, n-size, tag | 4 + 4 + 3 | Rows and columns of this B tile |
| AC | k-size, m-size, tag | 4 + 4 + 3 | Columns and rows of this A tile |
| OC | `first`, `last`, `gemm_last`, m-size, n-size, ID, tag | 1 + 1 + 1 + 4 + 4 + 4 + 3 = 18 | `first` = (k == 0), `last` = (k == last); both set = "only" pass. `gemm_last` = final pass of the GEMM; ID is returned on `out_ack` (§9.1). Delayed to match the psums (§9.1) |

- **No addresses.** WC and AC own their read pointers (§7.2); the next tile in the bank is by definition this
  pass's tile. Shapes stay in TC.
- **Tag (3 bits):** a pass index mod 8. About 4 passes are alive at once (WC on p+1, AC on p, p−1 in the array, OC
  on p−2), so 2 bits would have no margin. In-order fixed latency already matches commands to data; the tag is for
  checking and debug.
- **Edge padding (engine pads).** The array always runs a full 16×16 pass; the units fill the gaps:

| Partial dim | Done by | Action |
|---|---|---|
| K (k-size < 16) | WC and AC | WC loads zero weight rows for rows ≥ k-size (the load still takes 16 shift cycles). AC zeroes A lanes ≥ k-size. Zeroing one side is enough arithmetically; zeroing both keeps don't-care (possibly X) lanes out of the array in simulation |
| M (m-size < 16) | AC, OC | AC sends 16 rows: the real ones, then zero rows marked invalid. The pass keeps its 16 cycles (a shorter pass would leave a bubble, as the next weight load takes 16). OC ignores the invalid psum rows |
| N (n-size < 16) | WC, OC | WC zeroes weight columns ≥ n-size. OC doesn't output them (encoding [OPEN], §13 #1). With n-size ≤ 8, the C out R stream is idle for that block |

### 9.4 Command flow example
A 32×48 · B 48×32 (M = 32, K = 48, N = 32): r ∈ {0, 1}, n ∈ {0, 1}, k ∈ {0, 1, 2}, so 2 · 2 · 3 = **12 passes**.

**Step 0, one external command.** The host sends `cmd` {ID=5, M=32, K=48, N=32} and gets an accept response
{ID=5, done=0, no warnings} (§9.6). At the end it gets {ID=5, done=1, status OK}. It programs upstream
(testbench, later a DMA) with the same shape.

**Step 1, upstream streams in pass order** (16 beats per tile, data only):

| # | A stream | B stream |
|---|---|---|
| 1 | A00 | B00 |
| 2 | A01 | B10 |
| 3 | A02 | B20 |
| 4 | A00 (re-sent) | B01 |
| 5 | A01 | B11 |
| 6 | A02 | B21 |
| 7 | A10 | B00 (re-sent) |
| … | … | … |
| 12 | A12 | B21 |

**Step 2, TC issues one pass command per pass.** For each pass it advances (r, n, k), waits until both banks hold
the next tile's rows (16 here; fewer for an edge tile), and issues the commands:

| Pass | (r, n, k) | OC command | OC action on that pass's psums |
|---|---|---|---|
| 1 | (0, 0, 0) | first | ACC ← psum |
| 2 | (0, 0, 1) | — | ACC ← ACC + psum |
| 3 | (0, 0, 2) | last | C00 out ← ACC + psum |
| 4 | (0, 1, 0) | first | ACC ← psum |
| … | … | … | … |
| 12 | (1, 1, 2) | last | C11 out, then `done` |

**Step 3, the units overlap in time** (16 cycles per pass; psums leave the array about 2 passes after their
activations enter):

```
cycles    0-15     16-31    32-47    48-63    64-79
WC        load B00 load B10 load B20 load B01 load B11   <- one pass ahead
AC        -        A00 (1)  A01 (2)  A02 (3)  A00 (4)
OC        -        -        -        pass 1   pass 2     <- about 2 passes behind
```

In any window, WC works on pass p+1, AC on pass p and OC on about p−2. That is why OC's command is delayed.

### 9.5 Consistency between upstream and the engine
With push streams the loop nest exists twice: in upstream (to generate the streams) and in TC (for tile sizes,
pass types and completion). Both are programmed with the same shape, and keeping them consistent is **software's
job**, as with commercial DMA + engine pairs (§9.7). The streams carry data only, like a plain DMA stream.

- **Tile boundaries** come from TC's own counters, not from the stream: the units count rows, and TC knows each
  tile's size from the descriptor.
- **No mismatch detection in v1.** If upstream and the descriptor disagree (say upstream was given K = 32 and the
  descriptor K = 48), tiles are paired wrongly and C is wrong with no error. If upstream sends fewer rows than the
  shape implies, TC waits at a pass boundary forever (no timeout in v1). Sending more makes the extra rows the
  start of the next GEMM.
- **Debug option for later** (§13 #7): sideband markers on the streams (a tile-last bit, block-first / block-last
  bits) that TC checks against its own counters, turning a mismatch into an error status.

### 9.6 Response channel and abort
All acknowledgements and results return on one bus, `resp` (DV out, no stall, like AXI's write-response channel):
{ID, done, info}, 8 bits. Every accepted descriptor gets exactly two responses, in command order: an **accept**
and an **end**.

| Field | Width | Meaning |
|---|---|---|
| `ID` | 4 b | echoed from the descriptor |
| `done` | 1 b | 0 = accept response, 1 = end response |
| `info` | 3 b | read according to `done` (below) |

**Accept** (`done` = 0): sent when TC takes the descriptor into its queue (2 entries, for back-to-back GEMMs, §13
#5). It means "accepted", not "started", so the host can still abort cheaply. `info` = warnings:

| `info` bit | Set when |
|---|---|
| 0 | M field = 0 (runs as 65 536) |
| 1 | K field = 0 |
| 2 | N field = 0 |

**End** (`done` = 1): sent when the GEMM ends, i.e. when OC reports that the GEMM's last C row has left
(`out_ack` with this ID, §9.1), or on abort. `info` = status (3 bits, `RESP__INFO_ST_*`):

| Status | Meaning |
|---|---|
| 0 | OK |
| 1 | Reserved (e.g. a future stream-mismatch error or timeout) |
| 2 | Reserved |
| 3 | Aborted |
| 4–7 | Reserved |

In v1 an end response is either OK or aborted; codes 1 and 2 keep room for error reporting later.

- **ID:** chosen by the host, so it can serve as a job tag. At most 3 GEMMs are outstanding (1 running + 2 queued),
  so 2 bits would be unique; 4 bits leave the host room for its own numbering. Responses are in order, so the ID is
  for matching and debug, not reordering.
- **Response buffer:** at most 2 responses are produced in one cycle (one accept, since `cmd` takes at most one
  descriptor per cycle, and one end). `resp` sends one per cycle, so a collision leaves a backlog of 1, and the
  backlog can't grow: ends are tens of cycles apart (even a K = 16 GEMM), and accepts are limited by the queue. So
  one holding entry plus the output register is enough, with no path that stalls `cmd`. An assertion (holding
  entry full and a new response) checks this instead of extra logic. A response may leave one cycle late.

**Abort.** A one-cycle `abort` pulse drops everything at once. It is a soft reset of the control state; SRAM
contents can stay, because nothing reads them without pointers. It clears:
- the descriptor queue and TC's loop counters;
- WC/AC pointers and occupancy (both sides), discarding partial tiles;
- the in-flight valid / pass-command pipeline, so aborted passes produce no further `c0_valid` / `c1_valid`
  (psums left in the array are harmless once invalid);
- the PE weight double-buffer state (active buffer, pending `w_latch` / `a_first`).

TC then sends one end response with status 3 (aborted) **per outstanding descriptor** (queued, running, or fully
issued but still waiting for `out_ack`), one per cycle, in command order. The abort clears OC, so no `out_ack`
arrives for those GEMMs. It drains them from the queue in an abort state rather than through the
response buffer, which holds only one. Every accepted descriptor therefore still ends exactly once, and the host's
count of outstanding commands stays correct. `cmd` is stalled during the drain. From the abort until the next
descriptor is accepted, the engine holds `a_stall` and `w_stall` high.

**Pause** needs no command: upstream holds `valid` low and the engine stalls at the next pass boundary.
A graceful stop (finish the current block) is not supported in v1.

**Stale-beat contract (v1).** On abort, upstream must discard every beat of the aborted GEMM it still holds, and
send only the next GEMM's data after that. The stall only holds old beats back; if upstream sends them once the
stall drops, they would be taken as the next GEMM's first tile and shift every later tile. Upgrade path (§13 #8):
the stream beats carry the descriptor ID too, and the engine drops beats whose ID doesn't match the GEMM they are
for. That makes stale beats harmless without relying on upstream.

### 9.7 Push vs pull (for later)
Commercial designs split **access** from **execute**. A DMA engine (an AXI master with base addresses and
strides) pulls from DRAM into on-chip buffers, and the compute engine is fed locally: TPU v1's weight fetcher and
Unified Buffer, NVDLA's convolution buffer, Gemmini's `mvin` into the scratchpad. Software programs both with the
same shape. v1 keeps the engine a stream slave. The later upgrade path is to add a DMA/reader block that pulls by
address and pushes into the same input streams, with no engine change. Alternatively, TC could issue tile requests
(pull by tile index), which removes the ordering contract at the cost of a request channel and prefetch logic.

### 9.8 Hazards and global rules
**Hazards:** the weights for pass p+1 must be fully loaded before pass p+1 starts; the accumulator pipeline rule
(§8.2); the WC ↔ AC interlock (§9.1).

**System assumptions and global rules:**
- **Output never stalls.** Downstream (a buffer or cache, as with the TPU's accumulators and unified buffer)
  accepts every C half-row the cycle it's produced. A future stalling output would be handled by a local buffer,
  never by stalling the array.
- **Inputs never starve a started pass.** Upstream buffers (a unified-buffer-style activation store, and weight
  storage for several tiles, like the TPU's weight FIFO) feed the input streams. Stalls may happen **only between
  passes**: TC waits at a pass boundary until the next pass's tiles are fully in the banks (§7.2). Upstream may
  pause between beats; the banks absorb it.
- **No mid-stream stalls.** Once a pass starts, its 16 rows enter one per cycle.
- Single clock domain; synchronous active-high reset (matching the existing RTL).
- Handshake convention: data/valid/stall (DVS). A beat transfers when
  `valid` is high and `stall` is low.

---

## 10. Interfaces (v1, testbench-facing)
- **Control** (plain ports in v1; an APB/AXI-Lite wrapper comes later). DV/DVS buses are listed as one entry;
  the handshake is implied:

  | Bus | Dir | Payload |
  |---|---|---|
  | `cmd` | DVS in | {ID[3:0], M, K, N} = 52 b; 0 = 65 536 for each dimension (§9.2) |
  | `resp` | DV out | {ID[3:0], done, info[2:0]} = 8 b; accept with warnings, or end with status (§9.6) |
  | `abort` | in | one-cycle pulse; one aborted end response per outstanding ID (§9.6) |
- **Inputs:** two DVS streams of data only, in pass order (§7.2, §9.5):
  - **A:** `a_data` (16 × int8, one A row), `a_valid`, `a_stall`;
  - **B:** `w_data` (16 × int8, one B row), `w_valid`, `w_stall`.
- **Output:** two DV half-row streams, each with `valid` only (no stall or ready):
  - **C out L** (`c0_out`, `c0_valid`): C columns 0–7 of the current block, 8 × int32 per cycle;
  - **C out R** (`c1_out`, `c1_valid`): C columns 8–15, the same rows **8 cycles later**.

  Rows leave in a fixed order: blocks in the §8.1 order (r, then n), and rows 0..15 within each block, during the
  block's last pass. An edge block outputs only its m-size rows; how its unused columns are marked is [OPEN]
  (§13 #1). Downstream can place each half by counting; no address or tag is sent. Each half writes its
  own bank downstream, so the halves are never realigned (realigning would cost about 2k flops).

---

## 11. Verification plan
- **Reference model:** an exact integer GEMM (SV or Python) compared bit for bit with C.
- **Directed tests:** K = 16 (the "only" pass path), multi-pass blocks, the 48×48·48×64 example, back-to-back
  GEMMs, extreme values (all −128, all 127), and gaps between passes (bubbles must not touch the accumulator).
- **Descriptor warnings:** 0 fields (accept warnings and the simulation warning).
- **Response channel:** every accepted ID gets exactly one accept and one end, in order, with the right ID; an
  accept and an end in the same cycle (one leaves a cycle late, nothing lost); the buffer-overflow assertion
  never fires.
- **Edge tiles:** M, K, N not multiples of 16, including sizes 1, 15, 17 and k-size / n-size ≤ 8 (C out R idle).
- **Abort:** mid-pass, during a weight load and with a full descriptor queue (3 aborted end responses, one per
  cycle); then a new GEMM must produce a correct C (no stale state).
- **Input streams:** random `valid` gaps on A and B (passes may only start on whole tiles), sustained full rate
  (no bubbles once the banks are primed), and ring-buffer wraparound, including tiles that straddle the wrap point.
- **Random tests:** random M, K, N (any value, weighted toward small and edge sizes) and random data; Icarus for directed runs, Verilator for long
  regressions.
- **Memories in `RDW_X=1` mode** for every regression.
- **Lint:** `verilator --lint-only -Wall` clean.
- **Performance check:** measured cycles vs the §8.4 model.

### Milestones
1. Spec (this document) written.
2. 16×16 array + skew + ACC: one block, correct for any K.
3. Full tiling + sequencer (descriptor → commands).
4. Random-shape regression against the reference model.
5. Performance measurement; then synthesis/PPA and v2.

---

## 12. v1 → v2 comparison (plan)
v2 adds muxes at the core boundaries (activation source, `p` source), per-core control and sequencer modes
(independent, N-split, K-split). Both versions use the same `pe`/`systolic` RTL: v1 as one 16×16 instance, v2 as
four 8×8 instances. Hierarchy alone doesn't change the netlist once flattened, so the comparison isolates the cost of
flexibility. One small confound: v1 uses 20-bit psums in every PE, while v2's top-row cores may use 19.
Metrics, recorded for both versions:
- **Area:** muxes, extra banks, sequencer and control logic.
- **Timing:** a mux in front of a core's first PE sits on the multiply-add path unless the core boundary is registered.
- **Utilization:** small or odd shapes where a fixed 16×16 wastes PEs.
- **Complexity:** lines of control RTL, test scenarios, bugs found.

---

## 13. Open items

| # | Item | Needed before |
|---|---|---|
| 1 | Edge blocks with n-size < 16: per-lane valids on `c0_out` / `c1_out`, or "columns ≥ n are undefined, downstream knows N" (§9.3) | milestone 3 |
| 2 | OC delay mechanism (valid + command pipeline alongside the array, or a small queue) and the TC → unit handshake details (§9.3) | P1 control |
| 3 | Output end-of-block / end-of-GEMM marker (`c_last`) for downstream, needed with back-to-back GEMMs | milestone 3 |
| 4 | Exact A/B bank depth (≥ 24, §7.2): how much upstream jitter to absorb | milestone 3 |
| 5 | Back-to-back GEMMs: preload the next GEMM's first weights during the current one's last passes | milestone 3 |
| 6 | ~~Owner of the WC ↔ AC interlock~~ Resolved: direct signals between WC and AC (§9.1) | — |
| 7 | Upstream / descriptor mismatches are not detected; optional debug markers on the streams (§9.5) | later |
| 8 | Descriptor ID on the stream beats, replacing the stale-beat contract (§9.6) | when a real DMA sits upstream |

---

## 14. Decision log

| Decision | Reason |
|---|---|
| One 16×16 `systolic` instance, no muxes (v1) | Simplest correct design; same `pe`/`systolic` RTL as v2's cores, so the v1/v2 comparison still holds |
| One psum width (20 bits) in every PE | Simpler; costs about 128 flops vs per-row sizing (not trimmed by synthesis) |
| Weight stationary, double-buffered weights | Reuses the verified PE and array (`rtl/pe.sv`, `rtl/systolic.sv`); weight loads hidden behind compute |
| R = 16 | Smallest bubble-free pass with a 16-deep weight chain; sets the accumulator at 1 KB |
| k innermost | The accumulator holds one C block; each block finishes before the next starts |
| int8 × int8 → int32, fixed | Industry-standard inference format; bit-exact verification; one configuration to verify |
| No bias | Not needed for GEMM; can be added later at the accumulator's first-pass adder with no array change |
| Width-split banks with read-timing offsets | Removes the 8-cycle delay lines (64 words per path) for a modest bank overhead |
| Accumulator in SRAM, not per-column FIFOs | At depth 16, per-column FIFOs would be about 8k flops |
| Direct output on the last pass | Output never stalls, so the free-read-port drain only added cost |
| Two half-row output streams, 8 cycles apart | Matches the bank timing; realigning would cost about 2k flops |
| Output and input never stall mid-pass | System buffers (unified-buffer / weight-FIFO style) absorb it; the array can't stall |
| A and B stream in over DVS; C leaves as two DV streams | Loading overlaps compute; the output never stalls, so it needs no ready |
| A/B banks are ring buffers, ≥ 24 rows | 16 + 8 is the floor for full throughput (bank R frees rows 8 cycles late); extra rows only absorb jitter |
| Upstream re-sends A for every n (B for every r), in pass order | Reuse belongs in the next storage level; bank depth stays independent of the GEMM shape |
| WC/AC own their bank pointers and external stalls; TC owns descriptor, loops and checks | Occupancy is computed where both pointers live; pass commands need no addresses |
| One external command per GEMM (M, K, N); TC derives first/last | Shapes live in one place; per-pass first/last bits from outside could contradict the shape |
| Descriptor in element counts, 16 b each, 0 = 65 536 | Low 4 bits give the edge-tile size for free; no invalid encoding; K ≤ 65 536 rules out int32 overflow |
| Edge tiles handled in hardware, engine pads | Any M, K, N runs; upstream sends only real data |
| Pass commands carry 4-bit sizes (0 = 16) and a 3-bit tag | Sizes drive the padding; about 4 passes are alive, so 3 bits leave margin |
| One `resp` DV channel {ID, done, info}: accept with zero-field warnings, end with 2-bit status | One place for the host to watch; a 0 field is legal (65 536) but almost always a bug, and flagging it at accept lets the host abort |
| Response buffer of one entry, no stall path | At most 2 responses per cycle and the backlog can't exceed 1; checked by an assertion |
| 4-bit host-chosen ID in `cmd`, echoed in `resp` | Cheap; works as a job tag; later also on stream beats to drop stale data |
| Abort = soft reset of control state, one aborted response per outstanding ID, stale-beat contract | Cheap and robust; the host's outstanding count stays correct; pause needs no command; IDs on beats can replace the contract later |
| Input streams carry data only; units report rows, TC derives tile boundaries | Matches a plain DMA stream; consistency is software's job, as in commercial designs. Markers stay a later debug option |
| WC ↔ AC interlock as two direct signals ("weights loaded", "pass started") | Local to two neighbouring units; TC stays a pure sequencer |
| End response on OC's `out_ack` {ID}, triggered by a `gemm_last` bit in the OC command | "Done" means the last C row has left; TC can't know that at issue time, and with back-to-back GEMMs the ack needs the ID |
| One broadcast `w_latch` pulse, timed as in an N×N array | The PEs carry it one column per cycle, and the bank-R read offset + triangle give columns 8–15 the same skew as a 0→15 triangle |
