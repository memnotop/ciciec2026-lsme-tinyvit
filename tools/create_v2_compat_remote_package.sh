#!/usr/bin/env bash
# 生成“已验证 V2 cached 硬件 + 软件 RMSNorm 回退”的远程演示包。
#
# 这不是 V2 + 硬件 RMSNorm 的替代发布：目标是给当前已恢复 UART 的远程板
# 提供一组物理配置已验证、ABI 精确匹配、可稳定录制的 V2 核心演示文件。

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT_DIR/release/v2_cached_compat_remote_20260813"}
KNOWN_GOOD_DIR="$ROOT_DIR/release/remote_demo_zh_20260726"
VERIFY_DIR="$ROOT_DIR/build/verification"

SOURCE_BIT="$KNOWN_GOOD_DIR/lsme_tinyvit_xai_pinyin_stream_v1.bit"
SOURCE_TIMING="$KNOWN_GOOD_DIR/timing_summary.rpt"
SOURCE_UTIL="$KNOWN_GOOD_DIR/dsp_utilization.rpt"
SOURCE_DRC="$KNOWN_GOOD_DIR/drc.rpt"
README_TEMPLATE="$ROOT_DIR/tools/templates/v2_compat_remote_README.md"
SCRIPT_TEMPLATE="$ROOT_DIR/tools/templates/v2_compat_video_script_60s.md"
METRICS_TEMPLATE="$ROOT_DIR/tools/templates/v2_compat_verified_metrics.md"
SIM_LOG="$VERIFY_DIR/tinyvit_v2_compat_old_v2_sim_clean.log"
COMPAT_BIN="$ROOT_DIR/sdk/tinyvit_v2_compat.bin"
COMPAT_ELF="$ROOT_DIR/sdk/software/examples/tinyvit_v2_compat/obj/tinyvit_v2_compat.elf"
COMPAT_MIF="$ROOT_DIR/sdk/axi_ram.mif"
PROBE_BIN="$ROOT_DIR/sdk/lsme_v2_compat_boot_probe.bin"
PROBE_ELF="$ROOT_DIR/sdk/software/examples/lsme_v2_compat_boot_probe/obj/lsme_v2_compat_boot_probe.elf"
PROBE_MIF="$ROOT_DIR/sdk/axi_ram.mif"

EXPECTED_BIT_SHA=6657d382705532f503a17c45e8258a3c1e58b994ee14b80cc995cb9bc7f1414a

for artifact in "$SOURCE_BIT" "$SOURCE_TIMING" "$SOURCE_UTIL" "$SOURCE_DRC" \
                "$README_TEMPLATE" "$SCRIPT_TEMPLATE" "$METRICS_TEMPLATE" \
                "$SIM_LOG"; do
    if [[ ! -f "$artifact" ]]; then
        printf '缺少兼容包所需文件：%s\n' "$artifact" >&2
        exit 1
    fi
done

if [[ "$(sha256sum "$SOURCE_BIT" | awk '{print $1}')" != "$EXPECTED_BIT_SHA" ]]; then
    printf '已验证 bitstream 的 SHA-256 不匹配，停止打包。\n' >&2
    exit 1
fi
if ! grep -q 'TINYVIT_V2_COMPAT_PASS' "$SIM_LOG"; then
    printf 'V2 兼容 SoC 仿真没有 PASS 标志，停止打包。\n' >&2
    exit 1
fi
if ! grep -q 'V2C_CAP lacc=02404088 csr=0240409f' "$SIM_LOG"; then
    printf 'V2 兼容 SoC 仿真能力字不符合旧 ABI，停止打包。\n' >&2
    exit 1
fi

# 先生成完整 V2 cached 软件并保存它对应的 MIF，再生成精确 ABI probe。
make -C "$ROOT_DIR" software-v2-compat
for artifact in "$COMPAT_BIN" "$COMPAT_ELF" "$COMPAT_MIF"; do
    [[ -f "$artifact" ]] || { printf '缺少兼容固件：%s\n' "$artifact" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"
install -m 0644 "$COMPAT_BIN" "$OUT_DIR/lsme_tinyvit_v2_cached_compat.bin"
install -m 0644 "$COMPAT_ELF" "$OUT_DIR/tinyvit_v2_cached_compat.elf"
install -m 0644 "$COMPAT_MIF" "$OUT_DIR/tinyvit_v2_cached_compat.mif"

make -C "$ROOT_DIR" boot-probe-v2-compat
for artifact in "$PROBE_BIN" "$PROBE_ELF" "$PROBE_MIF"; do
    [[ -f "$artifact" ]] || { printf '缺少兼容 probe：%s\n' "$artifact" >&2; exit 1; }
done
install -m 0644 "$PROBE_BIN" "$OUT_DIR/lsme_v2_cached_compat_probe.bin"
install -m 0644 "$PROBE_ELF" "$OUT_DIR/lsme_v2_cached_compat_probe.elf"
install -m 0644 "$PROBE_MIF" "$OUT_DIR/lsme_v2_cached_compat_probe.mif"

# 恢复工作区默认 MIF 为完整兼容演示，便于后续复现或重新打包。
make -C "$ROOT_DIR" software-v2-compat

install -m 0644 "$SOURCE_BIT" "$OUT_DIR/lsme_v2_cached_compat.bit"
install -m 0644 "$SOURCE_TIMING" "$OUT_DIR/timing_summary.rpt"
install -m 0644 "$SOURCE_UTIL" "$OUT_DIR/dsp_utilization.rpt"
install -m 0644 "$SOURCE_DRC" "$OUT_DIR/drc.rpt"
install -m 0644 "$SIM_LOG" "$OUT_DIR/tinyvit_v2_cached_compat_sim.log"
install -m 0644 "$README_TEMPLATE" "$OUT_DIR/README.md"
install -m 0644 "$SCRIPT_TEMPLATE" "$OUT_DIR/video_script_60s.md"
install -m 0644 "$METRICS_TEMPLATE" "$OUT_DIR/verified_metrics.md"

{
    printf '# Bitstream lineage and verification boundary\n\n'
    printf -- '- `lsme_v2_cached_compat.bit` is a byte-for-byte copy of the known-good remote bitstream.\n'
    printf -- '- SHA-256: `%s`.\n' "$EXPECTED_BIT_SHA"
    printf -- '- The same old V2 RTL rebuilt on 2026-08-13 has an identical configuration payload from byte 132 onward; only the standard bitstream header differs.\n'
    printf -- '- The current compatibility firmware was simulated against that old V2 RTL and produced `TINYVIT_V2_COMPAT_PASS`.\n'
    printf -- '- Hardware capability is `LACC=02404088`, `CSR=0240409f`: 64 lanes, cached V2, Softmax and VADD; no hardware RMSNorm.\n'
    printf -- '- Therefore the three RMSNorm steps in `lsme_tinyvit_v2_cached_compat.bin` intentionally use the bit-exact software path.\n'
    printf -- '- Do not cite this package as V2 + HW RMSNorm remote-board evidence.\n'
} > "$OUT_DIR/bitstream_lineage.md"

ARTIFACTS=(
    lsme_v2_cached_compat.bit
    lsme_tinyvit_v2_cached_compat.bin
    tinyvit_v2_cached_compat.elf
    tinyvit_v2_cached_compat.mif
    lsme_v2_cached_compat_probe.bin
    lsme_v2_cached_compat_probe.elf
    lsme_v2_cached_compat_probe.mif
    timing_summary.rpt
    dsp_utilization.rpt
    drc.rpt
    tinyvit_v2_cached_compat_sim.log
    README.md
    video_script_60s.md
    verified_metrics.md
    bitstream_lineage.md
)

{
    printf 'LSME-128I V2 cached remote compatibility package\n'
    printf 'Hardware: known-good V2 cached configuration; software: exact RMSNorm fallback.\n'
    printf 'Probe marker: LSME_V2_COMPAT_BOOT_PROBE_PASS\n'
    printf 'Demo marker: TINYVIT_V2_COMPAT_PASS\n'
    printf 'Do not claim hardware RMSNorm for this package.\n\n'
    (cd "$OUT_DIR" && sha256sum "${ARTIFACTS[@]}")
} > "$OUT_DIR/BUILD_MANIFEST.txt"

(
    cd "$OUT_DIR"
    sha256sum "${ARTIFACTS[@]}" > SHA256SUMS
)

printf '已生成 V2 cached 兼容远程演示包：%s\n' "$OUT_DIR"
printf '上传顺序：.bit → BaseRAM 偏移 0 的 probe.bin → 完整 compat.bin。\n'
