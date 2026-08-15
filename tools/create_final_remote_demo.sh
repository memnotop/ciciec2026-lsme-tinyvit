#!/usr/bin/env bash
# 生成可上传远程 FPGA 平台的 V2 + RMSNorm 演示包。
#
# 同时输出三份互不混淆的固件：
#   1) 标准展示版：串口文案最完整；
#   2) 远程精简版：运算/DVI/ABI 完全相同，但二进制更小，作为实板首选；
#   3) 启动探针：只验证 CPU、UART、LACC 和 CSR，用于故障分界。

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT_DIR/release/final_remote_demo_20260813"}
BITSTREAM="$ROOT_DIR/fpga/project/Loongson_Soc.runs/impl_1/soc_top.bit"
FULL_ELF="$ROOT_DIR/sdk/software/examples/tinyvit_demo/obj/tinyvit_demo.elf"
REMOTE_ELF="$ROOT_DIR/sdk/software/examples/tinyvit_remote/obj/tinyvit_remote.elf"
PROBE_ELF="$ROOT_DIR/sdk/software/examples/lsme_v2_boot_probe/obj/lsme_v2_boot_probe.elf"
VERIFY_DIR="$ROOT_DIR/build/verification"

if [[ ! -f "$BITSTREAM" ]]; then
    printf '缺少 bitstream：%s\n请先执行 make bitstream。\n' "$BITSTREAM" >&2
    exit 1
fi

# 防止 RTL/约束已变而 bitstream 未重建。
STALE_SOURCE=$(find "$ROOT_DIR/rtl" "$ROOT_DIR/fpga/constraints" \
    -type f -newer "$BITSTREAM" -print -quit)
if [[ -n "$STALE_SOURCE" ]]; then
    printf 'bitstream 早于源文件：%s\n请先执行 make impl && make bitstream。\n' \
        "$STALE_SOURCE" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# 先构建标准展示版并立即保存它对应的仿真初始化文件。
make -C "$ROOT_DIR" software
install -m 0644 "$ROOT_DIR/sdk/user-sample.bin" \
    "$OUT_DIR/lsme_tinyvit_v2_rmsnorm.bin"
install -m 0644 "$FULL_ELF" "$OUT_DIR/tinyvit_demo_v2_rmsnorm.elf"
install -m 0644 "$ROOT_DIR/sdk/axi_ram.mif" "$OUT_DIR/axi_ram.mif"

# 构建远程首选版。它复用同一 tinyvit_runtime.c 和同一 RTL/ABI，只压缩非必要文案。
make -C "$ROOT_DIR" software-compact
install -m 0644 "$ROOT_DIR/sdk/tinyvit_remote.bin" \
    "$OUT_DIR/lsme_tinyvit_v2_rmsnorm_remote.bin"
install -m 0644 "$REMOTE_ELF" "$OUT_DIR/tinyvit_remote_v2_rmsnorm.elf"
install -m 0644 "$ROOT_DIR/sdk/axi_ram.mif" \
    "$OUT_DIR/tinyvit_remote_v2_rmsnorm.mif"

# 构建板级启动探针；此镜像不含模型权重，适合先判断 V2 bitstream 是否真的启动。
make -C "$ROOT_DIR" boot-probe
install -m 0644 "$ROOT_DIR/sdk/lsme_v2_boot_probe.bin" \
    "$OUT_DIR/lsme_v2_boot_probe.bin"
install -m 0644 "$PROBE_ELF" "$OUT_DIR/lsme_v2_boot_probe.elf"
install -m 0644 "$ROOT_DIR/sdk/axi_ram.mif" \
    "$OUT_DIR/lsme_v2_boot_probe.mif"

# 恢复工作区默认的软件初始化镜像，避免后续 make sim 意外使用诊断探针。
make -C "$ROOT_DIR" software

install -m 0644 "$BITSTREAM" "$OUT_DIR/lsme_tinyvit_v2_rmsnorm.bit"
install -m 0644 "$ROOT_DIR/fpga/project/dsp_utilization.rpt" \
    "$OUT_DIR/dsp_utilization.rpt"
install -m 0644 "$ROOT_DIR/fpga/project/timing_summary.rpt" \
    "$OUT_DIR/timing_summary.rpt"
install -m 0644 "$ROOT_DIR/fpga/project/hierarchical_utilization.rpt" \
    "$OUT_DIR/hierarchical_utilization.rpt"
install -m 0644 "$ROOT_DIR/fpga/project/congestion.rpt" \
    "$OUT_DIR/congestion.rpt"
install -m 0644 "$ROOT_DIR/fpga/project/drc.rpt" "$OUT_DIR/drc.rpt"

# 验证日志只有在明确保存为对应变体后才收集，避免把“最近一次仿真”错标给另一份固件。
if [[ -f "$VERIFY_DIR/tinyvit_remote_v2_rmsnorm_sim.log" ]]; then
    install -m 0644 "$VERIFY_DIR/tinyvit_remote_v2_rmsnorm_sim.log" \
        "$OUT_DIR/tinyvit_remote_v2_rmsnorm_sim.log"
fi
if [[ -f "$VERIFY_DIR/lsme_v2_boot_probe_sim.log" ]]; then
    install -m 0644 "$VERIFY_DIR/lsme_v2_boot_probe_sim.log" \
        "$OUT_DIR/lsme_v2_boot_probe_sim.log"
fi

ARTIFACTS=(
    lsme_tinyvit_v2_rmsnorm.bit
    lsme_tinyvit_v2_rmsnorm.bin
    tinyvit_demo_v2_rmsnorm.elf
    axi_ram.mif
    lsme_tinyvit_v2_rmsnorm_remote.bin
    tinyvit_remote_v2_rmsnorm.elf
    tinyvit_remote_v2_rmsnorm.mif
    lsme_v2_boot_probe.bin
    lsme_v2_boot_probe.elf
    lsme_v2_boot_probe.mif
    dsp_utilization.rpt
    timing_summary.rpt
    hierarchical_utilization.rpt
    congestion.rpt
    drc.rpt
)
for optional_log in tinyvit_demo_v2_rmsnorm_sim.log \
                    tinyvit_remote_v2_rmsnorm_sim.log \
                    lsme_v2_boot_probe_sim.log; do
    [[ -f "$OUT_DIR/$optional_log" ]] && ARTIFACTS+=("$optional_log")
done

{
    printf 'LSME-128I V2 + streaming RMSNorm remote demo package\n'
    printf 'Hardware bitstream: routed XC7A200T implementation\n'
    printf 'Remote recommendation: lsme_tinyvit_v2_rmsnorm_remote.bin (compact V2 full demo)\n'
    printf 'Boot split probe: lsme_v2_boot_probe.bin\n'
    printf 'Standard presentation firmware: lsme_tinyvit_v2_rmsnorm.bin\n'
    printf 'Demo controls: SW[3:0]=manual sample, SW[15]=automatic carousel\n'
    printf 'Key remote markers: TINYVIT_BOOT_V2_COMPACT / TINYVIT_V2_PASS\n'
    printf 'PPA source: reports copied from the same routed implementation as the bitstream\n'
    printf '\nArtifacts:\n'
    (cd "$OUT_DIR" && sha256sum "${ARTIFACTS[@]}")
} > "$OUT_DIR/BUILD_MANIFEST.txt"

(
    cd "$OUT_DIR"
    sha256sum "${ARTIFACTS[@]}" > SHA256SUMS
)

printf '远程演示包已生成：%s\n' "$OUT_DIR"
printf '首选上传：.bit → BaseRAM 偏移 0 的 remote.bin → 复位。\n'
printf '若无 UART：同一 .bit 配合 boot_probe.bin 先作启动分界。\n'
