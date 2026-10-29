# GEMM Engine

A tiled integer GEMM accelerator in SystemVerilog, built around a 16×16 weight-stationary systolic array
with double-buffered weights. It computes **C = A · B** for signed int8 matrices of any shape
(M, K, N from 1 to 65 536) with exact int32 results, streaming tiles through the array back to back.

> **Status:** work in progress. The v1 design is complete (array, banks, top/weight/activation/output
> controllers and accumulator) and passes end-to-end checks against a reference matmul. See [Status](#status).
> The full specification is in [`docs/spec.md`](docs/spec.md).

## At a glance

| | |
|---|---|
| Array | One 16×16 weight-stationary array (256 MACs/cycle), handled as two 8-lane halves |
| Data types | int8 × int8 → int32 accumulate, signed, bit-exact (20-bit psums inside the array) |
| GEMM shapes | Any M, K, N in 1 … 65 536; edge tiles are zero-padded in hardware |
| Dataflow | k-innermost tiling; 16 A rows per weight tile ("pass"), one pass every 16 cycles |
| Weight loads | Hidden behind compute: each PE double-buffers its weight, so the next tile loads while the current one computes |
| Buffers | 1R1W SRAM banks (behavioral models): A and B ring buffers (2 × 32 rows each), 1 KB accumulator |
| Control | One descriptor per GEMM {ID, M, K, N}; accept/end responses; abort |
| Throughput | 16 cycles per pass, ≈ 16 · (M/16)(N/16)(K/16) + 64 cycles of fill and drain; measured 90% at 48×48 · 48×64, 97% for four back to back |

## Architecture

```
                          B stream in (16 × int8 per beat)
                     ┌───────────┴───────────┐
              B bank L (N 0-7)        B bank R (N 8-15)    <- bank R read 8 cycles later
                     │ 0→7 skew              │ 0→7 skew
                     ▼                       ▼
                 ┌──────────────────────────────────────┐
 A bank T  ─0→7─►│  rows 0-7                             │
 (K 0-7)    skew │      16×16 weight-stationary array    │
 A bank B  ─0→7─►│  rows 8-15                            │
 (K 8-15)   skew │  cols 0-7                 cols 8-15   │
                 └──────────┬─────────────────────┬──────┘
                            │ 7→0 de-skew         │ 7→0 de-skew
                            ▼                     ▼
                 ACC bank L (C 0-7)      ACC bank R (C 8-15)   <- read-modify-write
                            │                     │
                            ▼                     ▼
                 C out L (cols 0-7)      C out R (cols 8-15)   <- two half-row streams, 8 cycles apart
```

- **Width-split banks.** Every buffer is split into two 8-lane halves. The upper half's extra 8 cycles of skew
  come from reading its bank 8 cycles later, so only two 0→7 skew triangles are needed per path instead of a
  0→15 triangle.
- **Tiling.** For each C block (r, n), the engine runs K/16 passes. Each pass holds one 16×16 B tile in the
  array, streams the matching 16 rows of A through it, and accumulates into the 16×16 int32 accumulator.
  The last pass of a block sends the result straight to the C output instead of writing it back.
- **Control.** A top controller (TC) walks the tile loops from the descriptor and issues pass commands to
  the weight (WC), activation (AC) and output (OC) controllers. WC and AC own their bank pointers and the
  input stalls, and hand off to each other directly so loads and passes overlap with no bubbles.

### Interfaces

| Bus | Dir | Payload |
|---|---|---|
| `cmd` | DVS in | GEMM descriptor {ID[3:0], M, K, N}, 16-bit element counts (0 = 65 536) |
| `resp` | DV out | {ID, done, info}: an accept (with zero-field warnings), then an end (OK or aborted) per GEMM |
| `abort_req` | in | One-cycle pulse: drops all work; every outstanding GEMM ends as aborted |
| `w` (B stream) | DVS in | One 16 × int8 row of B per beat, tiles in pass order |
| `a` (A stream) | DVS in | One 16 × int8 row of A per beat, tiles in pass order |
| `c0` / `c1` | DV out | C columns 0–7 / 8–15, 8 × int32 per beat; `c1` runs 8 cycles behind `c0` |
| `c_hdr` | DV out | Block header with each block's first `c0` row: block position, m/n sizes, GEMM ID |

The input streams carry data only: the engine knows every tile boundary from the descriptor, and upstream
(a testbench now, a DMA later) sends tiles in the loop order. DVS = data/valid/stall; DV = data/valid.

## Repository layout

| Path | Contents |
|---|---|
| `docs/spec.md` | v1 specification: architecture, dataflow, control, interfaces, verification plan, decision log |
| `rtl/` | Generic modules shared by all versions (no project package) |
| `rtl/pe.sv`, `rtl/systolic.sv` | Processing element with double-buffered weights; M×M array of PEs |
| `rtl/skew.sv`, `rtl/delay_line.sv` | Skew/de-skew triangles built from parameterized delay lines |
| `rtl/ram_1r1w.sv` | 1R1W SRAM wrapper (behavioral; can be swapped for a macro), optional X on read-during-write |
| `rtl/sync_fifo.sv` | Small flop-based FIFO for control queues |
| `prj/v1/` | GEMM engine v1: package, top level and controllers |
| `prj/v1/gemm_v1_pkg.sv` | Widths, geometry, bank depths, descriptor/command/response formats |
| `prj/v1/gemm_top.sv` | Top level: array, skew, banks, controllers |
| `prj/v1/top_controller.sv` | Descriptor sequencer: tile loops, pass commands, responses, abort |
| `prj/v1/weight_controller.sv`, `activation_controller.sv`, `out_controller.sv` | Unit controllers (in progress) |
| `prj/v1/v1.f` | Design file list |

## Running

Requires [Icarus Verilog](https://github.com/steveicarus/iverilog) 12 and/or
[Verilator](https://www.veripool.org/verilator/) 5. Run from the repository root.

The repository holds the design only. The testbenches used to bring it up are not part of it; [`docs/spec.md`](docs/spec.md) §11 records the verification plan and what was run. These commands elaborate and lint the design:
```
mkdir -p build
iverilog -g2012 -c prj/v1/v1.f -s gemm_top -o build/gemm_top.vvp
verilator --lint-only -Wall -f prj/v1/v1.f --top-module gemm_top
```
Verilator reports width and unused-signal warnings; a lint clean-up is pending.

## Status

| Milestone | State |
|---|---|
| Specification (`docs/spec.md`) | Draft; some controller sections still to be brought up to date |
| PE, array, skew, SRAM wrapper, FIFO | Done |
| Top level wiring | Done |
| Top controller: loops, pass commands, responses, abort | Done |
| Weight, activation and output controllers, accumulator | Done |
| End-to-end checks: reference matmul, edge shapes, K = 65 536, aborts, back-to-back GEMMs | Passing (bring-up testbenches, not part of the repository) |
| Performance against the cycle model | Done: 16 cycles/pass, 90% at 48×48 · 48×64 |
| Lint clean-up | To do |
| Synthesis / PPA, then v2 | Planned |

## Roadmap: v2

v2 rebuilds the same 16×16 array from four 8×8 instances of the same `pe` / `systolic` RTL, with muxes at
the core boundaries, so the cores can run independently or be regrouped (N-split, K-split) for small or
odd shapes. Because both versions share the core RTL, the cost of that flexibility (area, timing, control
complexity) can be measured directly against the utilization it buys. Later items: DMA/AXI front end,
synthesis with an open-source flow, and output backpressure.
