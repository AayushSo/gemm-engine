#!/bin/bash
# GEMM engine v1: synthesis and pre-layout STA with OpenROAD-flow-scripts (ORFS), nangate45, in Docker.
#
# Usage (from anywhere):
#   syn/run.sh [synth|sta|all|pnr]                default: all (synth, then sta)
#                                                 pnr: the full flow through routing (ORFS "finish")
#   CLK_PERIOD=4.0 syn/run.sh                     clock period in ns (default in syn/constraint.sdc);
#                                                 a variant's SDC is fixed at synthesis, so use a new
#                                                 VARIANT for each period
#   VARIANT=hier_all SYNTH_HIERARCHICAL=1 SYNTH_MINIMUM_KEEP_SIZE=0 syn/run.sh synth
#                                                 keep every module; then syn/area_by_module.py
#                                                 gives the per-module area
#   LEC_CHECK=0 syn/run.sh pnr                    skip ORFS's final equivalence check (it needs more
#                                                 than the 8 GB Docker has on this design)
#   INFER_CLKGATES=1 syn/run.sh                   map flop enables to clock-gating cells (yosys clockgate)
#   HOLD_SLACK_MARGIN=0.05 syn/run.sh pnr         repair hold to this margin (ns) instead of 0
#   SETUP_SLACK_MARGIN=0.01 syn/run.sh pnr        repair setup to this margin (ns) instead of 0
#   CORE_UTILIZATION=65 PLACE_DENSITY=0.72 syn/run.sh pnr
#                                                 floorplan (defaults in syn/config.mk: 40, 0.60)
#   ORFS_IMAGE=openroad/orfs:<tag> syn/run.sh     ORFS image (default below)
#
# Outputs, per variant: build/syn/{logs,reports,results,objects}/nangate45/gemm_v1/<variant>/
#   reports/.../synth_stat.txt   cell area (yosys)
#   reports/.../sta.rpt          worst paths, WNS/TNS, minimum period (OpenSTA, on 1_synth.odb)
#   reports/.../6_finish.rpt     post-route timing, area, power (pnr)
#
# The run does not depend on the terminal; to let it outlive the shell:
#   setsid nohup syn/run.sh > build/syn/run.log 2>&1 &
set -euo pipefail
trap 'echo "FAILED: exit $? at line $LINENO"' ERR

cd "$(dirname "$0")/.."
REPO=$PWD
IMAGE=${ORFS_IMAGE:-openroad/orfs@sha256:90683468be0f7c820f625f329ae6c89a16de42e82955ae69e3c94a8d93735a14}	# the image the documented results came from
VARIANT=${VARIANT:-base}
STEP=${1:-all}

PLAT=nangate45
NICK=gemm_v1
WORK=/work/build/syn
OUT=$PLAT/$NICK/$VARIANT

case $STEP in
	synth) TARGETS="synth" ;;
	sta)   TARGETS="" ;;
	all)   TARGETS="synth" ;;
	pnr)   TARGETS="finish" ;;
	*)     echo "usage: $0 [synth|sta|all|pnr]"; exit 1 ;;
esac

mkdir -p build/syn
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"

# env passed into the container (empty values are ignored by ORFS / the SDC)
ENVS=(-e CLK_PERIOD -e SYNTH_HIERARCHICAL -e SYNTH_MINIMUM_KEEP_SIZE -e LEC_CHECK -e INFER_CLKGATES -e HOLD_SLACK_MARGIN -e SETUP_SLACK_MARGIN -e CORE_UTILIZATION -e PLACE_DENSITY)

docker run --rm -v "$REPO":/work -w /OpenROAD-flow-scripts/flow "${ENVS[@]}" "$IMAGE" bash -c "
	set -euo pipefail
	[ -f ../env.sh ] && source ../env.sh >/dev/null
	MK='make DESIGN_CONFIG=/work/syn/config.mk WORK_HOME=$WORK FLOW_VARIANT=$VARIANT'
	if [ -n '$TARGETS' ]; then \$MK $TARGETS; fi
	if [ '$STEP' = sta ] || [ '$STEP' = all ]; then
		ODB=$WORK/results/$OUT/1_synth.odb
		[ -f \$ODB ] || { echo \"no synthesized design (\$ODB); run synth first\"; exit 1; }
		LIB=\$(\$MK -s print-LIB_FILES | sed -n 's/^LIB_FILES: *//p' | awk '{print \$1}') \
		ODB=\$ODB SDC=/work/syn/constraint.sdc \
			timeout 1800 openroad -no_init -no_splash -exit /work/syn/sta.tcl | tee $WORK/reports/$OUT/sta.rpt
	fi
"
echo "done: build/syn/reports/$OUT/"
