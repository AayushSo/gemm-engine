# GEMM engine v1: synthesis, place and route, and power

This note records how v1 was taken through synthesis, place and route, gate-level simulation and power analysis
with an open-source flow. It covers what was run, the problems hit on the way, the results, and what they suggest
doing next. The design is described in [`microarch.pdf`](microarch.pdf), which carries a summary of this document.

## Summary

| | Result |
|---|---|
| Library / corner | Nangate45, typical (1.10 V, 25 °C) |
| Cell area | 422 645 µm² after synthesis |
|  | 428 256 µm² (for 2.0 ns target) and 430 999 µm² (for 1.5 ns target) after place and route |
| Die | 1.06 mm², 41% utilization (40% target) |
| Clock | before layout: 1.705 ns |
|  | after routing: 1.66 ns at a 2.0 ns target and **1.50 ns (667 MHz) at a 1.5 ns target**, typical corner |
| Critical path | AC's `a_first` register → PE weight select → 8 × 8 multiply → 20-bit psum add → `p_out` |
| Function | both routed netlists (2.0 ns and 1.5 ns), simulated at gate level, are bit-exact on a real workload (63 308 C rows) |
| Power at 500 MHz | 341 mW on random int8 GEMMs; **279 mW on an image filter bank**; 139 mW idle|
| Energy | 2.7 pJ per MAC (random GEMMs, 97% utilization); 3.9 pJ per useful MAC (filter bank, K = 9).|

## Tools

| Tool | Use |
|---|---|
| [OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts) (ORFS), Docker image `openroad/orfs@sha256:90683468be0f…` | the whole flow; `syn/run.sh` pins this digest |
| Yosys with the slang frontend, ABC | synthesis (SystemVerilog packages, structs and unpacked ports read as written) |
| OpenROAD | floorplan, placement, clock tree, routing, parasitic extraction |
| OpenSTA (inside OpenROAD) | timing and power |
| Icarus Verilog 12 | simulation for switching activity |
| Python (numpy, PyMuPDF) | activity extraction, workload generation, reports |

The flow ran on my laptop: WSL2 + Docker Desktop with 12 CPUs and 8 GB of memory.

## 1. Synthesis and pre-layout timing

Files in [`syn/`](../syn):

| File | Purpose |
|---|---|
| `config.mk` | ORFS design config: top `gemm_top`, Nangate45, the RTL in `v1.f` order, slang frontend, floorplan settings |
| `constraint.sdc` | one clock on `clk` (5 ns default, `CLK_PERIOD` overrides); inputs and outputs at 20% of the period |
| `run.sh` | runs ORFS in Docker: `synth`, `sta`, `all` (synth + sta) or `pnr`; one output tree per `VARIANT` under `build/syn/` |
| `sta.tcl` | worst path per path type (reg→reg, in→reg, reg→out), WNS/TNS, minimum period per type |
| `area_by_module.py` | per-block area from a fully hierarchical synthesis |

Commands:

```
syn/run.sh                                                         # flat synthesis + STA (variant "base")
VARIANT=hier_all SYNTH_HIERARCHICAL=1 SYNTH_MINIMUM_KEEP_SIZE=0 syn/run.sh synth
python3 syn/area_by_module.py build/syn/reports/nangate45/gemm_v1/hier_all/synth_stat.txt
```

Steps and findings:

1. The slang frontend read the RTL with no changes and no warnings; Yosys's check found no problems.
2. The flat netlist: 184 921 cells, 32 114 flops, 422 645 µm², 34% of it sequential.
3. Timing (ideal clock, the library's default wire-load model):
   * reg→reg 1.705 ns
   * in→reg 1.107 ns
   * reg→out 0.874 ns
4. The critical path runs from AC's `a_first[15]` register into the `p_out` register of PE (8, 7): about 0.24 ns of
   buffering for the `a_first` fanout, 0.18 ns for the weight select (`weight_flag_next = a_first ^ weight_flag` drives
   the mux in front of the multiplier), then the multiply and the psum add.
5. Block area (from hierarchical synthesis):

   | Block | Area (µm²) | Share |
   |---|---|---|
   | Systolic array (256 PEs at approx 1 050 µm² each) | 268 950 | 60.8% |
   | Accumulator banks (8 Kb of flops) | 72 918 | 16.5% |
   | Weight banks (4 Kb) | 35 698 | 8.1% |
   | Activation banks (4 Kb) | 35 178 | 8.0% |
   | Skew and deskew | 13 813 | 3.1% |
   | gemm_top wrapper logic | 9 560 | 2.2% |
   | Four controllers with their FIFOs | 6 270 | 1.4% |

Learnings:

- ORFS maps with ABC's speed script, which does not use the clock period -> a 1.6 ns target gives the same netlist.
  Closing a tighter clock is placement and routing's job (gate sizing, buffering).
- `run.sh` passes `CLK_PERIOD` into the SDC, but ORFS writes a variant's SDC out after synthesis with the value
  fixed. Use a new `VARIANT` for each period.
- OpenROAD needs the technology before it can link a Verilog netlist, so `sta.tcl` reads ORFS's `1_synth.odb`.
- `report_clock_min_period` did not finish on this design in 10 minutes; `sta.tcl` computes the minimum period per
  path type from the worst slack instead.

## 2. Place and route

```
LEC_CHECK=0 VARIANT=pnr_2000 CLK_PERIOD=2.0 syn/run.sh pnr
LEC_CHECK=0 VARIANT=pnr_1500 CLK_PERIOD=1.5 syn/run.sh pnr
```

The first target, 2.0 ns, sits above the 1.705 ns pre-layout estimate to leave room for wires and clock skew; the
second, 1.5 ns, looks for this RTL's limit. Floorplan for both: 40% core utilization, 0.60 placement density. Stage
times for the 2.0 ns run:

| Stage | Time | Peak memory | Notes |
|---|---|---|---|
| Synthesis | 2.5 min | 1.3 GB | |
| Floorplan | 45 s | 0.9 GB | die, tap cells, power grid |
| Placement | 7 min | 2.2 GB | worst slack +0.31 ns after global placement |
| Clock tree | 11 s | 1.0 GB | 32 114 sinks, 8 buffer levels |
| Global route | 12.5 min | 3.0 GB | |
| Detailed route | 25 min | 6.4 GB | violations 25 327 → 4 199 → 2 805 → 69 → 0 |
| Final report | 7.5 min | 4.4 GB | |

Results (typical corner):

| Metric | 2.0 ns target | 1.5 ns target |
|---|---|---|
| Minimum clock period | 1.66 ns (= 601 MHz) | 1.50 ns (= 667 MHz) |
| Setup slack | +0.34 ns | 0.00 ns (WNS = TNS = 0) |
| Hold slack | +0.03 ns | +0.02 ns |
| Cell area | 428 256 µm² (+1.3% over synthesis) | 430 999 µm² (+2.0%) |
| Timing-repair buffers | 3 983 | 6 967 |
| Clock tree | 7 330 buffers, 1 952 inverters; skew = 0.04 ns | 7 365 buffers, 1 824 inverters; skew = 0.05 ns |
| Die | 1.06 mm², about 1 030 µm square | same |
| Routing | 0 DRC violations | 0 DRC violations |
| Worst IR drop | 4.8 mV | 6.3 mV |


Timing is quoted at the typical corner with 50 ps of clock uncertainty. Signoff would need slow-corner setup and
fast-corner hold analysis (and on-chip-variation derates), but the Nangate45 library in this flow ships only the typical
corner, so those are not available here.

Endpoints on the 2.0 ns layout by the period their worst path needs: 1 080 need more than 1.5 ns, all PE `p_out`
bits on paths from `a_first` (AC's or a PE's forwarded copy); 12 975 need more than 1.0 ns, of which 4 024 are PE
`p_out` bits and 8 449 are bank-flop writes (read pointers through the occupancy check to the bank enables, and OC's
first/accumulate select into the ACC).

Learnings:

- ORFS's final equivalence check (kepler-formal) ran out of Docker's 8 GB and was killed without a verdict;
  `LEC_CHECK=0` skips it. The same check after clock-tree synthesis passed on the 2.0 ns run; the later steps only
  add buffers and resize cells, and the gate-level simulations of both final netlists are bit-exact.

## 3. Gate-level simulation

The final equivalence check could not run, so the routed netlist (`6_final.v`) is simulated directly: it checks the
netlist's function on a real workload and gives a VCD whose names match the netlist, for the power cross-check
(section 4).

1. **Cell models.** ORFS ships no Verilog simulation models for Nangate45 (the platform's `cells_*.v` files are Yosys
   mapping templates). Zero-delay models are generated from the liberty file's own `function` and `ff` definitions:
   115 cells. Latches and clock-gating cells are skipped since the netlist doesn't use them.
2. **Wrapper.** The netlist's top module is renamed `gemm_top_gl`, and a wrapper with the RTL port list maps the
   unpacked lanes onto the netlist's flat buses, so the RTL testbenches drive it unchanged. Their internal probes are
   disabled for gate level.
3. **Speed.** Icarus compiles the netlist in 22 s (2 GB) and runs about 16 cycles per second (0.8 GB), roughly 100×
   slower than RTL.

Result: one frame of the filter-bank workload (31 654 × 9 × 16; 31 753 cycles, 33 minutes) is bit-exact: all
63 308 C rows and 1 979 block headers match the numpy reference. The 1.5 ns netlist gives the same result (31 minutes).

Notes:

- RAM flops have no reset. Words never written stay X at gate level (e.g. the accumulator when K ≤ 16), which
  affects only the gate-level power cross-check (section 4); initializing them at time 0 avoids it.
- The models have no delays, so this checks function, not timing, and the power from it has no glitches. A
  timing-annotated (SDF) simulation would be needed for both; Icarus's SDF support is limited.

## 4. Power


### Method

1. **Workload simulation.** A testbench drives `gemm_top` with a real workload in Icarus Verilog. A dump module,
   compiled next to it, writes a VCD of the DUT over a steady-state window. Icarus does not dump unpacked arrays, so
   the dump module names every register-array word explicitly (RAM and FIFO words, delay-line stages, output
   registers, the input lanes): 392 words.
2. **Activity per flop.** OpenSTA's `read_vcd` matched only 2 569 of about 688 000 pins: the flat netlist's names do
   not follow the VCD hierarchy. Flop *instances*, however, keep their RTL register names
   (`u_systolic.genblk1[4].genblk1[9].u_pe.p_out[18]$_SDFF_PP0_`), so a script turns the VCD into toggles per cycle and
   duty for every register bit and matches them to flops by instance name: 31 470 of 32 114 flops (98%). The rest
   are registers the netlist renamed (`c0_out_r`/`c1_out_r`, some skew stages).
3. **Annotation.** `set_power_activity` sets that activity on every matched flop's Q and QN and on the input ports;
   OpenSTA propagates it through the logic.
4. **Power.** OpenSTA on the routed design with its extracted parasitics (SPEF), at the 2.0 ns clock (500 MHz),
   Nangate45 typical. The simulation clock does not matter: activity is in transitions per cycle.
5. **Per block.** Flops keep their block in their names; every other cell is assigned to the block of the nearest
   flop it feeds (a backward walk from all flop inputs through the routed netlist). Clock-tree cells form their own
   group.
6. **Idle.** All data activity set to zero with the clock running.
7. **Buffers and the rest.** The three buffers (A, B and accumulator banks: 17 152 flops, including their read-data
   registers) are separated from everything else. Each side gets its flops, the logic feeding them, and a share of the
   clock tree: the clock network is traced from `clk`, and each clock cell's power is split by the buffer and
   non-buffer flops below it (the buffers' share is 36.9 of 72.7 mW in every workload).


### Workloads

- **Random GEMMs:** four 48×48 · 48×64 GEMMs back to back, random int8 data, 97.3% utilization; window of 2 200
  steady-state cycles.
- **Image filter bank:** a three-frame grayscale video snippet, each frame downscaled to 240×135 and centred to int8,
  filtered by 16 classic 3 × 3 kernels (Sobel, Prewitt, line detectors, Laplacians, blur, sharpen, emboss) scaled to
  int8. Through im2col each frame is one GEMM of 31 654 × 9 × 16; the three run back to back (5 937 passes at exactly
  16 cycles per pass). A file-driven testbench streams A and B from files in pass order and checks every C row:
  all 189 924 rows matched the numpy reference, and the engine's output rendered as the expected edge, blur and
  sharpen maps. Window: 4 000 cycles in the middle of the second frame. Run twice: padding lanes zero (what a
  sensible im2col DMA sends) and random (allowed by the stream contract).

### Results at 500 MHz

| Workload | Total | Array | Clock tree | Banks (excl. clock tree) | Mean flop activity | Energy |
|---|---|---|---|---|---|---|
| Random GEMMs | 341 mW | 173 mW | 73 mW | 60 mW | 0.18 / cycle | 2.7 pJ / MAC |
| Filter bank, zero padding | 279 mW | 120 mW | 73 mW | 59 mW | 0.10 / cycle | 3.9 pJ / useful MAC |
| Filter bank, random padding | 284 mW | 124 mW | 73 mW | 59 mW | 0.12 / cycle | 3.9 pJ / useful MAC |
| Idle (clock running, data static) | 139 mW | | 73 mW | | 0 | |

Filter bank by block (zero padding): array 120.0 mW (43%), clock tree 72.7 mW (26%), accumulator banks 31.6 mW
(11%), activation banks 14.5 mW, weight banks 13.1 mW, skew and deskew 9.4 mW, logic driving the output ports
9.3 mW, gemm_top own logic 5.7 mW, controllers 3.1 mW; total 279.4 mW.

Excluding the buffers (they are meant to become SRAM macros), with each side's share of the clock tree:

| Workload | Total | Buffers | Excluding buffers | Energy, total | Energy, excluding buffers |
|---|---|---|---|---|---|
| Random GEMMs | 341 mW | 102 mW | 239 mW | 2.7 pJ / MAC | 1.9 pJ / MAC |
| Filter bank, zero padding | 279 mW | 99 mW | 181 mW | 3.9 pJ / useful MAC | 2.5 pJ / useful MAC |
| Filter bank, random padding | 284 mW | 98 mW | 185 mW | 3.9 pJ / useful MAC | 2.6 pJ / useful MAC |
| Idle | 139 mW | 71 mW | 68 mW | | |

- E.g. for the filter bank (zero padding), the buffers' 99 mW = flops 52 mW + their share of the clock
  tree 37 mW + logic 9 mW.

By register type inside the PEs (random GEMMs):

| Register | Flops | Power | Cycles it changes value |
|---|---|---|---|
| `p_out` | 5 056 | 25.3 mW | 100% |
| `a_out` | 1 920 | 12.2 mW | 99.7% |
| `weight0`, `weight1` | 2 × 2 048 | 2 × 5.7 mW | 26% each |
| `weight_flag`, `weight_upd`, `weight_lock` | 3 × 256 | 2.1 mW | 6–12% |

### Cross-check against the gate-level simulation

The per-flop method was checked against native power on identical cycles: frame 1 of the filter bank, cycles
2 000–3 000, on the 2.0 ns layout. The gate-level VCD (every netlist net, 280 MB) is read by OpenSTA's `read_vcd`
directly and annotates 684 432 of 688 340 pins.

| | Per-flop method | Gate-level VCD |
|---|---|---|
| Flops | 112.2 mW | 111.5 mW |
| Logic (not flops, not clock tree) | 94.3 mW | 79.5 mW |
| Clock tree | 72.7 mW | 72.7 mW |
| **Total** | **279.2 mW** | **263.6 mW** |

- Flop activity agrees: within 1% in total, identical for individual flops.
- Statistical propagation overestimates logic power by 19%: it treats each gate's inputs as independent, which
  inflates the toggling in the multipliers' XOR-heavy adder trees. The per-flop totals are therefore about 6% high.
- The gate-level run itself needed one correction. The accumulator is never written in this workload (K = 9 gives
  single-pass blocks), so its 8 704 flops stay X, and OpenSTA counts X-valued flops as drawing no internal power. Real
  flops still burn their clocking; those 30.0 mW are taken from the per-flop run (233.6 mW before the correction).

### Limits

- Zero-delay simulation: glitch power in the multipliers and adders is not counted (typically 10–30% more logic power).
- Typical corner only.
- Combinational activity is propagated statistically from the annotated flops, not simulated: logic power about 19%
  high (cross-check above).
- 2% of the flops take propagated activity.


## 5. Conclusions

1. **Timing.** v1 closes 1.5 ns (667 MHz) after routing, at the typical corner. The limit is the PE: the weight
   select sits in series with the multiply-accumulate, and `a_first` fans out across a diagonal before it reaches the
   select. The control paths the spec worried about (the combinational interlock, the accumulate) have margin.
2. **Area.** The array is 61% of the cells; the flop-based buffers are a third. As SRAM macros the buffers would shrink
   and about half of the flops would leave the clock tree.
3. **Clocking is almost half the power.** The clock tree (73 mW) and the flops' clock-driven internal power (58 mW)
   are 131 of the filter-bank's 279 mW and do not depend on the data: idle, the engine draws 139 mW. v1 has no
   clock gating.
4. **Real data matters.** Image data toggles about half as often as random int8 and cuts the array's power by 31%.
   Random-data power is close to a worst case.
5. **Padding lanes are not worth zeroing.** Random padding costs only 4 mW more than zeros: the zero weights already
   keep those rows' multipliers quiet.
6. **Partial K tiles raise energy per useful MAC.** Per hardware MAC, the filter bank costs
   2.2 pJ against random data's 2.7 pJ. But K = 9 uses 9 of 16 rows, so per useful MAC it costs 3.9 pJ: the idle rows
   still pay their clocking and pass psums down. The fix is in the mapping (v2's regrouped cores), not in gating.
7. **The routed netlists are functionally correct.** Simulated at gate level, both are bit-exact on a real workload,
   which stands in for the final equivalence check.
8. **The power numbers are slightly conservative.** The per-flop method is accurate for flops but reads logic power
   about 19% high, about 6% on the total; glitch power, which neither simulation counts, works the other way.

## 6. Next steps

**Power** (buffers left out: they become SRAM):

1. Clock-gate the PE weight buffers, each with its own capture enable: they hold in about 74% of cycles. Expected
   saving about 7–8 mW after the gating cells' own cost. With the enable written in the RTL, Yosys's `clockgate` pass
   can map the gating to Nangate's `CLKGATETST_X1`. A synchronous reset needs the gate open during reset, or no reset
   on these registers.
2. Gate the whole array's clock when no pass is in flight (from AC's go to OC's last read): up to about 50 mW whenever
   the engine waits. One gate high in the tree also stops the clock buffers below it.
3. Remove the synchronous reset from datapath flops (weights, `a_out`, `p_out`, skew stages): less area and power, a
   shorter critical path, simpler clock gating. Premise to check: nothing samples them before valid data.
4. Rerun the power flow with SRAM macros for the buffers.

**Clock speed:**

1. Take the weight select off the multiply path (send `a_first` one cycle early so the PE selects from a register, or
   keep an active weight register loaded at the swap): about 0.33 ns, which removes every path over 1.5 ns found so
   far and should allow about 750–800 MHz.
2. Beyond about 800 MHz: a pipelined MAC (carry-save product register; adds one cycle of latency, `OC_PSUM_LAT` + 1),
   the interlock go computed a cycle early, registered inputs, and a recheck of the bank write paths once the banks
   are SRAM macros.

**Experiments (tentative):**

1. Place and route at a higher core utilization (about 65% instead of 40%): the 1.06 mm² die is the area at the 40%
   target, not the design's minimum (its cells are 0.43 mm²). Watch routing convergence and timing.
2. Power with gaps in the input streams (below full rate): the baseline for gating the array's clock when idle.

**Flow:**

1. Slow and fast corners: not available in this library; a platform with corner libraries (sky130hd or ASAP7 in
   ORFS) would be needed for signoff-style numbers.
2. Glitch-aware power: a gate-level simulation with SDF delays.
3. Initialize the RAM flops at time 0 in gate-level runs, so never-written flops are not X.
4. The final equivalence check on a machine with more memory.
5. Bring the power and gate-level scripts into the repository along with a testbench.
