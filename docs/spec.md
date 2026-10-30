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
Measured on the RTL, from the cycle AC reads an A row (its pass start, "go", for row 0): the row's de-skewed psums
reach the accumulator **24 cycles** later for columns 0–7 (`OC_PSUM_LAT` = 1 `a_first` register + T + S − 1
de-skew) and 32 cycles later for columns 8–15. The C out row follows one cycle after that (output register).

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
| A (activations) | 2: T = K lanes 0–7, B = K lanes 8–15 | 8 × int8 = 64 b | 32 (`A_DEPTH`) | ring buffer; one word = 8 K-values of one A row |
| B (weights) | 2: L = N lanes 0–7, R = N lanes 8–15 | 8 × int8 = 64 b | 32 (`W_DEPTH`) | ring buffer; one word = 8 N-values of one B row |
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
- **Rows within a tile:** A tile rows in M order (row 0 first); **B tile rows in reverse K order** (row k-size − 1
  first, as a DMA reading with stride −1). The first row shifted into a weight column ends deepest, so this lets
  WC read the bank forward and free ring slots in order, with the array's K mapping unchanged (PE row k holds
  B row k).
- **A is re-sent for every n** (and B for every r). Reuse is handled by the next storage level upstream, not near
  the array, so bank depths don't depend on the GEMM shape. Cost: A input traffic × N/16. Holding the A strip in
  the bank instead (K rows, saving that traffic) is a candidate PPA experiment for later.
- **Whole tile before its load starts.** The skew delay lines run every cycle with no enable, so a weight load or
  an A stream can't pause partway. A pass (and the weight load feeding it) starts only when its whole tile is in
  the bank. That check happens at the pass boundary, the only place stalls are allowed (§9).
- **Depth 32** (`W_DEPTH`, `A_DEPTH`). A slot is free only once the *late* bank (R / B) has read it, 8 cycles after
  the early bank, and it can't be rewritten in the cycle it is read. A cycle model of the bank gives **25 rows as
  the floor** for 16 cycles per pass (24 gives 17). Rows above 25 help only when upstream gets ahead (GEMM start,
  edge tiles, a stall on the other stream); at steady state with full tiles the fill rate equals the drain rate, so
  a lost upstream beat is never made up, whatever the depth. 32 adds margin and makes the pointers wrap without a
  compare: they carry one extra wrap bit, so the depth must be a power of 2.
- **Edge tiles are shorter in the stream.** Upstream sends only real data: a partial B tile is k-size beats, a
  partial A tile is m-size beats. Lanes beyond the real width in a beat (n-size for B, k-size for A) are
  don't-care. The engine pads (§9.3).
- **Data only on the stream.** A beat carries one row and nothing else: no tile or block markers. Tile boundaries
  come from the descriptor: TC knows every tile's size (16, or the low 4 bits of the dimension at an edge), so it
  knows how many rows the next tile needs (§9.5).
- **Pointer ownership and per-row gating:** WC and AC each own their bank's write and read pointers. A row is
  written whenever a slot is free (occupancy counted from the late bank's read pointer); the external stall
  (`w_stall`, `a_stall`) is high only when all slots hold rows the late bank still needs. Rows may arrive before
  their pass command. A load or pass starts when the bank holds all rows of the next tile (counted from the early
  bank's read pointer) and the command for it is present. Nothing is reported to TC; reserving whole tiles per
  command instead was measured at 20.5 cycles per pass at depth 32.

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
  the pass length, so R = 16 is also the **smallest R that is bubble-free**. Only the first pass needs a 16-cycle
  preload; GEMMs sent back to back run on without a bubble (measured, §8.4).
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
- **Row tracking:** no valid bit travels with the psums. OC gets each pass's command from AC at the pass start and
  derives every row's handling from it and a fixed latency (§9.1), so bubbles between passes never trigger a fetch,
  write or output. The read → add → write pipeline is 2 cycles.
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
cycles ≈ 16 · (M/16)(N/16)(K/16) + 64, from the descriptor's accept to the last C row, with the input streams
ready. The 64 cycles are fixed:
- **fill, 32:** the first B tile's 16 rows arrive, then the 16-cycle weight load, before the first pass starts;
- **drain, 48 − 16:** the last pass's last `c1` row leaves 48 cycles after that pass starts (array 16 + de-skew 7
  + `a_first` and C out registers 2 + `c1` offset 8 + 15 rows), of which its own 16 cycles are already counted.

Measured on the RTL (joint testbench): the example takes **640 cycles, 576 / 640 = 90.0%**, and every pass is
16.00 cycles apart. Back-to-back GEMMs pay the fill and drain only once: the next GEMM's first pass starts 16
cycles after the previous one's last (4 × the example: 2368 cycles, 97.3%). Larger GEMMs approach 100%.

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
| Top controller (TC) | Descriptor intake, response channel, abort, the §8.1 loop counters and tile sizes. Issues one pass command per pass to WC and AC together, as fast as their command FIFOs take them; the units check their own banks (§7.2) |
| Weight controller (WC) | Accepts the B stream into banks L/R (owns their pointers, drives `w_stall`). From a pass command: reads one B tile (bank R 8 cycles later), pads it to 16×16 (§9.3), drives `w_latch` |
| Activation controller (AC) | Accepts the A stream into banks T/B (owns their pointers, drives `a_stall`). From a pass command: streams one A tile (bank B 8 cycles later), pads it to 16 rows (§9.3), drives `a_first`. Forwards the OC fields of the command to OC at the pass start |
| Output controller (OC) | Accumulator fetch / add / write, the C output streams and the block header, timed from the command AC forwards. Reports each finished GEMM to TC (`out_ack`) |

- **Command channel:** TC → WC (`wcmd`) and TC → AC (`acmd`) are DVS, each into a 4-entry FIFO in the unit. TC
  issues both commands of a pass in the same cycle; their stalls are shared (each unit's valid is gated by the
  other's stall), so both units always take a pass command together. AC's FIFO holds one more pass than WC's,
  because AC starts each pass 16 cycles after WC starts its weight load.
- **No row reporting:** each unit compares its own bank against the tile size in its command (§7.2), so TC needs
  no occupancy information and stays a pure sequencer.
- **Weights in flight:** W_m active in the PEs, W_m+1 loading into the idle weight buffers, W_m+2 arriving in the
  bank.
- **WC ↔ AC interlock, direct between the units.** WC holds a flag, `weight_stall`: "a tile is (being) latched into
  the idle weight buffers and its pass hasn't started". It is set so that it is visible at c = 16 of the load (c =
  cycles from the load start). AC starts a pass (its **go**) in the cycle it sees the flag, has the tile's A rows
  and its command; the go is combinational, and in the same cycle it clears the flag and lets WC start the next
  load. At full rate, load p+1, pass p's go and the end of load p meet at c = 16: the timing has zero slack, as
  checked on the array (`w_latch`, `a_first` and the next load's first weight arrive at PE[0][0] together).
- **`w_latch` timing:** a single registered pulse on all rows, at the array at **c = 17** of the load: the last
  weight row is read at c = 15 and reaches the array one cycle later (SRAM read latency). It enters column 0 and
  moves one column per cycle through the PEs, so column j sees it j cycles later, matching its weight skew.
  Columns 8–15 get their delay as 8 (bank R read offset) + (j − 8) (skew triangle). A short K tile still shifts all
  16 rows (zero rows first, §9.3), so `w_latch` stays at c = 17.
- **Pass command to OC:** several passes are in flight, so OC can't use TC's current command. TC puts the OC fields
  into `acmd`; AC forwards them (`ocmd`) at its go, which is the pass's real start. OC queues them (4-entry FIFO),
  starts bank 0 of the pass `OC_RD_START` = 23 cycles after the go, and bank 1 S cycles later (§5.4).
- **End of GEMM (OC → TC):** TC sets `gemm_last` on the GEMM's final pass command. OC pulses `out_ack` on bank 1's
  timeline of that pass's last row (the last C row's cycle if it is on C out R, 8 cycles after it if n-size ≤ 8).
  Bank 1 runs every pass even when it outputs nothing, so acks are in GEMM order and never two in one cycle. TC
  sends the end response for its oldest outstanding GEMM; GEMMs finish in order, so no ID is needed on the ack.

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
| AC | k-size + the OC fields below | 4 + 22 = 26 | Columns and rows of this A tile. The low 22 bits are laid out as the OC command |
| OC (from AC) | `first`, `last`, `gemm_last`, `r_first`, `r_last`, `n_first`, `n_last`, m-size, n-size, ID, tag | 1 + 1 + 1 + 4 + 4 + 4 + 4 + 3 = 22 | `first` = (k == 0), `last` = (k == last); both set = "only" pass. `gemm_last` = final pass of the GEMM (= `last && r_last && n_last`). `r_*` / `n_*` = block position and ID go on the output block header (§10). Forwarded by AC at the pass start (§9.1) |

- **No addresses.** WC and AC own their read pointers (§7.2); the next tile in the bank is by definition this
  pass's tile. Shapes stay in TC.
- **Tag (3 bits):** a pass index mod 8. About 4 passes are alive at once (WC on p+1, AC on p, p−1 in the array, OC
  on p−2), so 2 bits would have no margin. In-order fixed latency already matches commands to data; the tag is for
  checking and debug (bring-up checked that AC's pass tag always equals the tag of the tile WC loaded for it).
- **Edge padding (engine pads).** The array always runs a full 16×16 pass; the units fill the gaps:

| Partial dim | Done by | Action |
|---|---|---|
| K (k-size < 16) | WC | WC loads zero weight rows for rows ≥ k-size: the load still takes 16 shift cycles, with no read and the bank output forced to 0 for the first 16 − k-size (the real rows, sent in reverse K order, land in rows 0..k-size − 1). A lanes ≥ k-size are don't-care: they meet zero weights. Zeroing A as well would only keep X lanes from upstream out of simulation |
| M (m-size < 16) | AC, OC | AC reads the m-size real rows first, then idles for the rest of the pass (the array sees the last row again). The pass keeps its 16 cycles (a shorter pass would leave a bubble, as the next weight load takes 16). OC never outputs psum rows ≥ m-size |
| N (n-size < 16) | WC, OC | WC zeroes weight columns ≥ n-size (a lane mask at each bank's skew input, latched per load), so C columns ≥ n-size are exactly 0. C out still sends full half-rows; the block header's n-size tells downstream which lanes are valid (§10). With n-size ≤ 8, the C out R stream is idle for that block |

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

**Step 2, TC issues one pass command per pass.** For each pass it advances (r, n, k) and issues the commands as
soon as the units' command FIFOs take them; each unit then waits until its bank holds the tile's rows (16 here;
fewer for an edge tile):

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

In any window, WC works on pass p+1, AC on pass p and OC on about p−2. That is why OC gets its command from AC at
the pass start rather than from TC.

### 9.5 Consistency between upstream and the engine
With push streams the loop nest exists twice: in upstream (to generate the streams) and in TC (for tile sizes,
pass types and completion). Both are programmed with the same shape, and keeping them consistent is **software's
job**, as with commercial DMA + engine pairs (§9.7). The streams carry data only, like a plain DMA stream.

- **Tile boundaries** come from TC's own counters, not from the stream: TC puts each tile's size in the pass
  command, and the units count rows against it.
- **No mismatch detection in v1.** If upstream and the descriptor disagree (say upstream was given K = 32 and the
  descriptor K = 48), tiles are paired wrongly and C is wrong with no error. If upstream sends fewer rows than the
  shape implies, the units wait at a pass boundary forever (no timeout in v1). Sending more makes the extra rows the
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

**Accept** (`done` = 0): sent when TC takes the descriptor. TC holds one descriptor at a time and takes the next as
soon as it has issued every pass command of the current one, so GEMMs run back to back. `cmd` stalls otherwise,
and while 4 GEMMs are outstanding. It means "accepted", not "finished", so the host can still abort. `info` =
warnings:

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

- **ID:** chosen by the host, so it can serve as a job tag. Up to 4 GEMMs can be outstanding (TC's pending FIFO:
  the running one plus GEMMs fully issued but still waiting for `out_ack`, which happens with short GEMMs), so
  2 bits would be unique; 4 bits leave the host room for its own numbering. Responses are in order, so the ID is
  for matching and debug, not reordering. The ID also appears on the output block header (§10). The engine never
  checks it: matching by ID assumes the host keeps the IDs of outstanding GEMMs unique (a convention, not enforced).
- **Response buffer:** at most 2 responses are produced in one cycle (one accept, since `cmd` takes at most one
  descriptor per cycle, and one end). `resp` sends one per cycle, so a collision leaves a backlog of 1, and the
  backlog can't grow: ends are at least a cycle apart (`out_ack`, §9.1), and an accept happens at most once per
  GEMM. So one holding entry for the ack plus the output register is enough, with no path that stalls `cmd`. A
  simulation check (an ack while one is still held) guards this instead of extra logic. A response may leave one
  cycle late.

**Abort.** A one-cycle `abort` pulse drops everything at once. It is a soft reset of the control state; SRAM
contents can stay, because nothing reads them without pointers. It clears:
- TC's current descriptor and loop counters;
- WC/AC pointers, command FIFOs and pass counters, discarding partial tiles; WC's interlock flag and pending
  `w_latch`, and AC's go in the abort cycle;
- OC's command FIFO and pipeline, so aborted passes produce no further `c0_valid` / `c1_valid` / `c_hdr_valid`
  (psums left in the array are harmless once unused).

The array, skews and SRAMs are not reset. The PE weight double buffers must still end consistent, so two rules
apply:
- **`a_first` diagonals in flight are kept.** AC's `a_first` shift register is not cleared: a diagonal cut halfway
  would leave lanes swapped and unswapped.
- **Dummy `a_first`.** If a tile's `w_latch` has reached the array but its pass never started (WC's flag set, and
  not in the load's c = 16 cycle, where `w_latch` is still in its register and is cleared), the PEs are latched but
  not swapped. WC raises `dummy_a_first` in the abort cycle and AC sends one `a_first` diagonal with no data. In
  every other case the PEs are already consistent and no dummy is sent. Both rules were shown necessary in
  simulation (without them the next GEMM's C is wrong).

TC then sends one end response with status 3 (aborted) **per outstanding descriptor** (queued, running, or fully
issued but still waiting for `out_ack`), one per cycle, in command order. The abort clears OC, so no `out_ack`
arrives for those GEMMs. It drains them from the queue in an abort state rather than through the
response buffer, which holds only one. Every accepted descriptor therefore still ends exactly once, and the host's
count of outstanding commands stays correct. `cmd` is stalled during the drain. From the abort until the next
GEMM's first pass command reaches WC and AC, they hold `w_stall` and `a_stall` high.

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
  passes**: WC and AC wait at a pass boundary until the next pass's tile is fully in their bank (§7.2). Upstream
  may pause between beats; the banks absorb it.
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
- **Inputs:** two DVS streams of data only, in pass order; B tile rows in reverse K order (§7.2, §9.5):
  - **A:** `a_data` (16 × int8, one A row), `a_valid`, `a_stall`;
  - **B:** `w_data` (16 × int8, one B row), `w_valid`, `w_stall`.
- **Output:** two DV half-row streams and one DV block header, all with `valid` only (no stall or ready):

  | Bus | Dir | Payload |
  |---|---|---|
  | `c0` (C out L) | DV out | C columns 0–7 of the current block, 8 × int32 = 256 b |
  | `c1` (C out R) | DV out | C columns 8–15, the same rows **exactly 8 cycles later** |
  | `c_hdr` | DV out | {`r_first`, `r_last`, `n_first`, `n_last`, m-size[3:0], n-size[3:0], ID[3:0]} = 16 b, once per block |

  Rows leave in a fixed order: blocks in the §8.1 order (r, then n), and rows 0..m-size−1 of each block on
  consecutive cycles, during the block's last pass. Each half writes its own bank downstream, so the halves are
  never realigned (realigning would cost about 2k flops).

  **Block header (`c_hdr`).** Valid in the cycle of each block's first `c0` row (row 0); every block has at least
  one `c0` row, so one header on the `c0` timeline describes both halves. Fields:
  - `r_first` / `r_last`: first / last block row of the GEMM (r == 0, r == last); `n_first` / `n_last`: first /
    last block column (n == 0, n == last);
  - m-size, n-size: the block's rows and columns (4 bits, 0 = 16);
  - ID: the descriptor's ID (§9.2), so downstream can match blocks to the end response on `resp`.

  **Output contract** (downstream relies on it; the engine does not mark individual beats):
  - each active half sends exactly m-size rows per block; there is no per-beat end-of-block marker, downstream
    counts rows;
  - `c1` carries a block only if n-size > 8, and `c1` row x arrives exactly 8 cycles after `c0` row x. A `c1` row
    can arrive after the next block's header (blocks can overlap by up to 8 cycles; a short next block, even a
    whole short GEMM, can finish on `c0` before them), so downstream labels `c1`
    rows by the fixed offset (or a 2-entry header queue), not by the latest header;
  - valid lanes: `c0` lanes < min(n-size, 8), `c1` lanes < n-size − 8. Other lanes are 0 (the WC zeroes weight
    columns ≥ n-size);
  - a GEMM starts with the header that has `r_first && n_first`, and ends with the last row of the block with
    `r_last && n_last`: on `c1` if that block's n-size > 8, else on `c0`. `out_ack` (and so the end response)
    follows on the `c1` timeline of that row: the same cycle if n-size > 8, 8 cycles later if not. That keeps the
    acks in GEMM order and never two in one cycle;
  - abort: both halves stop in the same cycle, so the last block can be cut short (often only its `c1` rows,
    which trail). The next header with `r_first && n_first` is the resync point; `resp` reports the aborted GEMM
    by ID (§9.6).

  **ID agreement.** The engine does not check IDs. Matching blocks and responses by ID is only unambiguous if the
  host keeps the IDs of outstanding GEMMs unique (up to 4 can be outstanding: TC's pending FIFO). Order is still a fallback:
  GEMMs finish in order.

---

## 11. Verification plan
The repository holds the design only; the bring-up testbenches are not part of it. This section records the plan
and, under **Bring-up results**, what was run.

- **Reference model:** an exact integer GEMM (SV or Python) compared bit for bit with C.
- **Directed tests:** K = 16 (the "only" pass path), multi-pass blocks, the 48×48·48×64 example, back-to-back
  GEMMs, extreme values (all −128, all 127), and gaps between passes (bubbles must not touch the accumulator).
- **Descriptor warnings:** 0 fields (accept warnings and the simulation warning).
- **Response channel:** every accepted ID gets exactly one accept and one end, in order, with the right ID; an
  accept and an end in the same cycle (one leaves a cycle late, nothing lost); the buffer-overflow assertion
  never fires.
- **Edge tiles:** M, K, N not multiples of 16, including sizes 1, 15, 17 and k-size / n-size ≤ 8 (C out R idle).
- **Abort:** mid-pass, during a weight load and with a full descriptor queue (up to 4 aborted end responses, one
  per cycle); then a new GEMM must produce a correct C (no stale state).
- **Input streams:** random `valid` gaps on A and B (passes may only start on whole tiles), sustained full rate
  (no bubbles once the banks are primed), and ring-buffer wraparound, including tiles that straddle the wrap point.
- **Random tests:** random M, K, N (any value, weighted toward small and edge sizes) and random data; Icarus for directed runs, Verilator for long
  regressions.
- **Memories in `RDW_X=1` mode** for every regression.
- **Lint:** `verilator --lint-only -Wall` clean.
- **Performance check:** measured cycles vs the §8.4 model.

### Bring-up results
An end-to-end testbench drove `gemm_top` (all controllers, banks, skews, the real array and the accumulator) from
descriptors and A/B streams that follow the stream contract (lanes outside a tile carry garbage), with all
SRAMs in both `RDW_X` modes, and compared against an exact reference GEMM:
- every C half-row on `c0`/`c1` (values in valid lanes, cycle, no extra rows), every block header, every `out_ack`
  and every response (accept warnings, end status, order); also each pass's psums at the array and de-skew
  outputs, the `a_first` diagonal, the pass command fields and the WC/AC tile tags;
- shapes: 48×48×48, edge shapes (sizes 1–16 and non-multiples of 16, K < 16 straight after reset), random
  shapes up to 100 with up to 8 GEMMs per run, random gaps on both streams, K = 65 536 (field 0) with
  all −128 × −128 (C = 2³⁰) and −128 × 127;
- control: back-to-back GEMMs, `out_ack`/accept collisions, aborts swept over every pass phase and with 0–4 GEMMs
  outstanding (incl. a tile latched but its pass not started, which needs the dummy `a_first`);
- mutants (no dummy `a_first`, clearing in-flight `a_first` on abort, wrong output timing or fields) are caught.
All runs pass. Performance: §8.4.

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
| 1 | ~~Edge blocks with n-size < 16: per-lane valids, or "columns ≥ n are undefined"~~ Resolved: n-size on the output block header `c_hdr`; lanes beyond it are 0 (§10) | — |
| 2 | ~~OC delay mechanism and the TC → unit handshake~~ Resolved: AC forwards the OC command at the pass start, OC queues it (§9.1); `wcmd`/`acmd` DVS with shared stalls | — |
| 3 | ~~Output end-of-block / end-of-GEMM marker (`c_last`)~~ Resolved: one block header per block (position bits, sizes, ID); downstream counts m-size rows (§10) | — |
| 4 | ~~Exact A/B bank depth~~ Resolved: 32 rows; 25 is the floor for full rate (§7.2) | — |
| 5 | ~~Back-to-back GEMMs: preload the next GEMM's first weights~~ Resolved: the units don't see GEMM boundaries, so the next GEMM's first load overlaps the current one's last pass; no bubble measured (§8.4) | — |
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
| A/B banks are ring buffers of 32 rows | 25 is the floor for full throughput (the late bank frees rows 8 cycles late, and a slot isn't rewritten in the cycle it is read); 32 adds margin when upstream gets ahead and wraps without a compare |
| Per-row gating, not whole-tile reservation | A row is written as soon as a slot is free (counted from the late bank); reserving a tile per command cost 20.5 cycles per pass at depth 32, and counting free slots from the early bank let rows overwrite slots the late bank still needed |
| B tile rows arrive in reverse K order | WC reads forward and frees ring slots in order; the array's K mapping is unchanged; upstream only reads with stride −1 |
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
| Input streams carry data only; TC derives tile boundaries and sends tile sizes in the pass commands; units check their own banks | Matches a plain DMA stream; consistency is software's job, as in commercial designs. TC needs no occupancy report. Markers stay a later debug option |
| WC and AC take each pass command together (shared stalls) | Both units always hold the same passes; one handshake per pass for TC |
| WC ↔ AC interlock: WC's `weight_stall` flag, AC's combinational go in the same cycle | Full rate needs the go and the next load in the same cycle (zero slack at PE[0][0]); a registered go costs a cycle per pass. The path is one flop → AC → WC, with no loop |
| Abort: keep in-flight `a_first` diagonals, send a dummy `a_first` only for a tile latched but never swapped | The array isn't reset, and any fixed pulse sequence would break one of the two possible PE states; both rules were shown necessary in simulation |
| OC gets its command from AC at the pass start, not from TC | The go is the pass's real start, so OC's timing is a fixed offset from it with no valid pipeline alongside the array; it reuses AC's command FIFO |
| End response on OC's `out_ack`, on bank 1's timeline, triggered by `gemm_last` | "Done" means the last C row has left. On bank 1's timeline the acks are in GEMM order and never coincide; with both banks' acks, two GEMMs could end in one cycle and one would never get its end response |
| K padding by WC zero rows only; N padding by a WC column mask | One side is enough for K; the column mask makes C lanes ≥ n-size exactly 0 for a few dozen flops |
| One output block header (`c_hdr`) per block on the `c0` timeline, not per-stream or per-beat markers | `c1` row x is always `c0` row x + 8 and every block has a `c0` row, so one 16-bit header describes both halves; per-stream fields would cost 20 b and say the same. Downstream counts rows and uses the fixed offset; if the halves ever drift apart (output backpressure, v2's independent cores), per-stream fields come back |
| Block header carries position bits (`r_first`/`r_last`/`n_first`/`n_last`), m-size, n-size and the descriptor ID, not the pass tag | Enough to find GEMM starts and ends, valid lanes and block boundaries, and to resync after an abort. The tag is an internal pass counter that downstream can't match to anything; the ID is host-chosen and appears on `resp` |
| ID uniqueness is a host convention, not checked | Cheap; GEMMs finish in order, so order is a fallback when IDs repeat |
| One broadcast `w_latch` pulse, timed as in an N×N array | The PEs carry it one column per cycle, and the bank-R read offset + triangle give columns 8–15 the same skew as a 0→15 triangle |
