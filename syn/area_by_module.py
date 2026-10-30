# Per-block cell area from an ORFS hierarchical synth_stat.txt
# (VARIANT=hier_all SYNTH_HIERARCHICAL=1 SYNTH_MINIMUM_KEEP_SIZE=0 syn/run.sh synth).
# Usage: python3 syn/area_by_module.py build/syn/reports/nangate45/gemm_v1/hier_all/synth_stat.txt
import re, sys

t = open(sys.argv[1]).read()
# yosys prints each module's area including its submodules; module names are <module>$<instance path>
area = {n: float(a) for n, a in re.findall(r"Chip area for module '\\(\S+)': ([\d.]+)", t)}
top = area['gemm_top']
groups = [('u_systolic', 'Systolic array'), ('u_out_buf', 'Accumulator banks'), ('u_wei_buf', 'Weight banks'),
          ('u_act_buf', 'Activation banks'), ('u_skew', 'Skew and deskew'), ('u_top_controller', 'Controllers'),
          ('u_weight_controller', 'Controllers'), ('u_act_controller', 'Controllers'), ('u_out_controller', 'Controllers')]
agg = {}
for n, a in area.items():
    path = n.split('$', 1)[1].split('.') if '$' in n else []
    if len(path) != 2:                       # direct children of gemm_top only
        continue
    k = next((v for p, v in groups if path[1].startswith(p)), path[1])
    agg[k] = agg.get(k, 0) + a
agg['gemm_top (own logic)'] = top - sum(agg.values())
pe = [a for n, a in area.items() if n.startswith('pe$')]
for k, a in sorted(agg.items(), key=lambda x: -x[1]):
    print(f'{k:24s} {a:10.0f} um2  {100 * a / top:5.1f}%')
print(f'{"total":24s} {top:10.0f} um2')
if pe:
    print(f'PE: {len(pe)} x {sum(pe) / len(pe):.0f} um2')
