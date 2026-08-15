#!/usr/bin/env bash
set -euo pipefail

# 装配 RGB332 DVI 基线增量候选。bitstream 只允许改动已验证基线中的 DVI 外设。
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="$ROOT_DIR/release/cifar_tinyvit_rgb332_baseline_dvi_candidate_20260814"
IMPL_DIR="$ROOT_DIR/fpga/project_rgb332_baseline_dvi"
BIT_FILE="$IMPL_DIR/Rgb332BaselineDvi.runs/impl_1/soc_top.bit"
TIMING_RPT="$IMPL_DIR/timing_summary.rpt"
REUSE_RPT="$IMPL_DIR/incremental_reuse.rpt"
SOC_LOG="$ROOT_DIR/build/verification/cifar_rgb332_baseline_dvi_soc_sim.log"
DVI_LOG="$ROOT_DIR/build/verification/axi_dvi_rgb332_baseline_dvi_test.log"

make -C "$ROOT_DIR" software-cifar
if [ ! -f "$BIT_FILE" ] || [ ! -f "$TIMING_RPT" ] || [ ! -f "$REUSE_RPT" ] || \
   [ ! -f "$SOC_LOG" ] || [ ! -f "$DVI_LOG" ]; then
    printf 'Missing baseline-DVI validation output. Run make impl-rgb332-baseline-dvi and make sim-rgb332-baseline-dvi first.\n' >&2
    exit 1
fi
NON_REUSED_CELLS=$(awk -F'|' '/^\| Non-Reused Cells / {gsub(/[[:space:]]/, "", $3); print $3; exit}' "$REUSE_RPT")
if ! awk -v value="$NON_REUSED_CELLS" 'BEGIN { exit !(value <= 5.0) }'; then
    printf 'DVI 增量实现的非复用实例比例无效或超过 5%%：%s\n' "$NON_REUSED_CELLS" >&2
    exit 1
fi
mkdir -p "$OUT_DIR"
install -m 0644 "$BIT_FILE" "$OUT_DIR/00_cifar_rgb332_baseline_dvi.bit"
install -m 0644 "$ROOT_DIR/sdk/cifar_tinyvit_demo.bin" \
    "$OUT_DIR/01_cifar_tinyvit_rgb332.bin"
install -m 0644 "$ROOT_DIR/sdk/software/examples/cifar_tinyvit_demo/obj/cifar_tinyvit_demo.elf" \
    "$OUT_DIR/02_cifar_tinyvit_rgb332.elf"
install -m 0644 "$ROOT_DIR/sdk/software/examples/cifar_tinyvit_demo/obj/axi_ram.mif" \
    "$OUT_DIR/03_cifar_tinyvit_rgb332_axi_ram.mif"
install -m 0644 "$SOC_LOG" "$OUT_DIR/04_cifar_rgb332_baseline_dvi_soc_sim.log"
install -m 0644 "$DVI_LOG" "$OUT_DIR/05_axi_dvi_rgb332_baseline_dvi_test.log"
install -m 0644 "$TIMING_RPT" \
    "$OUT_DIR/06_timing_summary.rpt"
install -m 0644 "$REUSE_RPT" "$OUT_DIR/07_incremental_reuse.rpt"
sha256sum "$OUT_DIR/00_cifar_rgb332_baseline_dvi.bit" \
          "$OUT_DIR/01_cifar_tinyvit_rgb332.bin" \
          "$OUT_DIR/03_cifar_tinyvit_rgb332_axi_ram.mif" \
          "$OUT_DIR/04_cifar_rgb332_baseline_dvi_soc_sim.log" \
          > "$OUT_DIR/SHA256SUMS"
