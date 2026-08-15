#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/verilator"
mkdir -p "$BUILD"

RTL=(
    "$ROOT/rtl/ip/lsme/lsme_mopa_core.v"
    "$ROOT/rtl/ip/lsme/lsme_bram_tdp.v"
    "$ROOT/rtl/ip/lsme/lsme_core.v"
    "$ROOT/rtl/ip/lsme/lsme_softmax_core.v"
    "$ROOT/rtl/ip/lsme/lsme_udiv32.v"
    "$ROOT/rtl/ip/lsme/lsme_isqrt32.v"
    "$ROOT/rtl/ip/lsme/lsme_rmsnorm_core.v"
    "$ROOT/rtl/ip/lsme/lsme_axi_master.v"
    "$ROOT/rtl/ip/lsme/lsme_gemm_v2.v"
    "$ROOT/rtl/ip/lsme/lsme_exec_engine.v"
    "$ROOT/rtl/ip/lsme/lsme_csr_axi.v"
    "$ROOT/rtl/ip/lsme/lsme_top.v"
    "$ROOT/rtl/ip/lsme/lsme_lacc_cdc.v"
)

run_test() {
    local name="$1"
    local top="$2"
    local testbench="$3"
    shift 3
    local output="$BUILD/$name"
    rm -rf "$output"
    mkdir -p "$output"
    if ! verilator --binary --timing -j 0 -Wall -Wno-fatal \
        -I"$ROOT/rtl/ip/lsme" --top-module "$top" --Mdir "$output" \
        -o "V$name" "$@" "$ROOT/sim/$testbench" "${RTL[@]}" \
        >"$output/build.log" 2>&1; then
        cat "$output/build.log"
        return 1
    fi
    "$output/V$name"
}

for lanes in 16 32 64; do
    run_test "mopa_$lanes" lsme_mopa_tb lsme_mopa_tb.v "-GLANES=$lanes"
    run_test "core_$lanes" lsme_core_tb lsme_core_tb.v "-GLANES=$lanes"
done
run_test softmax lsme_softmax_tb lsme_softmax_tb.v
run_test rmsnorm lsme_rmsnorm_tb lsme_rmsnorm_tb.v
run_test axi_master lsme_axi_master_tb lsme_axi_master_tb.v
run_test gemm_v2 lsme_gemm_v2_tb lsme_gemm_v2_tb.v
run_test exec_engine lsme_exec_engine_tb lsme_exec_engine_tb.v
run_test top lsme_top_tb lsme_top_tb.v
run_test lacc_cdc lsme_lacc_cdc_tb lsme_lacc_cdc_tb.v

external_output="$BUILD/axi2sram_external"
rm -rf "$external_output"
mkdir -p "$external_output"
verilator --binary --timing -j 0 -Wall -Wno-fatal \
    --top-module axi2sram_sp_external_tb --Mdir "$external_output" \
    -o Vaxi2sram "$ROOT/sim/axi2sram_sp_external_tb.v" \
    "$ROOT/rtl/ip/Bus_interconnects/axi2sram_sp_external.v" \
    >"$external_output/build.log" 2>&1
"$external_output/Vaxi2sram"

# DVI 仪表盘既是现场演示的一部分，也是 AXI 外设；单独检查 XAI 画面、
# 固定数据流铭牌与 PASS/FAIL 状态带，避免只验证 LSME 计算核心。
dvi_output="$BUILD/axi_dvi_xai"
rm -rf "$dvi_output"
mkdir -p "$dvi_output"
verilator --binary --timing -j 0 -Wall -Wno-fatal \
    --top-module axi_dvi_xai_tb --Mdir "$dvi_output" \
    -o Vaxi_dvi_xai "$ROOT/sim/axi_dvi_xai_tb.v" \
    "$ROOT/rtl/ip/DVI/axi_dvi.v" >"$dvi_output/build.log" 2>&1
"$dvi_output/Vaxi_dvi_xai"

echo "LSME_RTL_REGRESSION_PASS"
