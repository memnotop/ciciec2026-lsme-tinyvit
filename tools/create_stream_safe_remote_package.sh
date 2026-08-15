#!/usr/bin/env bash
# 生成 V1 stream 实板安全演示包和 V2 burst 现场诊断包。

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT_DIR/release/stream_safe_remote_20260813"}
KNOWN_GOOD_DIR="$ROOT_DIR/release/remote_demo_zh_20260726"
VERIFY_DIR="$ROOT_DIR/build/verification"

SOURCE_BIT="$KNOWN_GOOD_DIR/lsme_tinyvit_xai_pinyin_stream_v1.bit"
SOURCE_TIMING="$KNOWN_GOOD_DIR/timing_summary.rpt"
SOURCE_UTIL="$KNOWN_GOOD_DIR/dsp_utilization.rpt"
SOURCE_DRC="$KNOWN_GOOD_DIR/drc.rpt"
README_TEMPLATE="$ROOT_DIR/tools/templates/stream_safe_remote_README.md"
SIM_LOG="$VERIFY_DIR/tinyvit_stream_safe_old_v2_sim.log"
BURST_SIM_LOG="$VERIFY_DIR/lsme_v2_burst_diag_old_v2_sim.log"
SAFE_BIN="$ROOT_DIR/sdk/tinyvit_stream_safe.bin"
SAFE_ELF="$ROOT_DIR/sdk/software/examples/tinyvit_stream_safe/obj/tinyvit_stream_safe.elf"
SAFE_MIF="$ROOT_DIR/sdk/software/examples/tinyvit_stream_safe/obj/axi_ram.mif"
BURST_BIN="$ROOT_DIR/sdk/lsme_v2_burst_diag.bin"
BURST_ELF="$ROOT_DIR/sdk/software/examples/lsme_v2_burst_diag/obj/lsme_v2_burst_diag.elf"

EXPECTED_BIT_SHA=6657d382705532f503a17c45e8258a3c1e58b994ee14b80cc995cb9bc7f1414a

for artifact in "$SOURCE_BIT" "$SOURCE_TIMING" "$SOURCE_UTIL" "$SOURCE_DRC" \
                "$README_TEMPLATE" "$SIM_LOG" "$BURST_SIM_LOG"; do
    [[ -f "$artifact" ]] || { printf '缺少安全包文件：%s\n' "$artifact" >&2; exit 1; }
done
if [[ "$(sha256sum "$SOURCE_BIT" | awk '{print $1}')" != "$EXPECTED_BIT_SHA" ]]; then
    printf '历史实板通过 bitstream 的 SHA-256 不匹配，停止打包。\n' >&2
    exit 1
fi
grep -q 'TINYVIT_STREAM_SAFE_PASS' "$SIM_LOG"
grep -q 'STREAM_SAFE_LOGITS 62495 12017 -1841 6929 -37231 -7190 17176 -18930 -4761 -23736' "$SIM_LOG"
grep -q 'LSME_V2_BURST_DIAG_PASS' "$BURST_SIM_LOG"

# 重新生成安全 MIF，然后生成诊断固件；最后再次恢复安全 MIF。
make -C "$ROOT_DIR" software-stream-safe
make -C "$ROOT_DIR" burst-diag
make -C "$ROOT_DIR" software-stream-safe

for artifact in "$SAFE_BIN" "$SAFE_ELF" "$SAFE_MIF" "$BURST_BIN" "$BURST_ELF"; do
    [[ -f "$artifact" ]] || { printf '缺少构建产物：%s\n' "$artifact" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"
install -m 0644 "$SOURCE_BIT" "$OUT_DIR/lsme_stream_safe.bit"
install -m 0644 "$SAFE_BIN" "$OUT_DIR/tinyvit_stream_safe.bin"
install -m 0644 "$SAFE_ELF" "$OUT_DIR/tinyvit_stream_safe.elf"
install -m 0644 "$SAFE_MIF" "$OUT_DIR/tinyvit_stream_safe.mif"
install -m 0644 "$BURST_BIN" "$OUT_DIR/lsme_v2_burst_diag.bin"
install -m 0644 "$BURST_ELF" "$OUT_DIR/lsme_v2_burst_diag.elf"
install -m 0644 "$SOURCE_TIMING" "$OUT_DIR/timing_summary.rpt"
install -m 0644 "$SOURCE_UTIL" "$OUT_DIR/dsp_utilization.rpt"
install -m 0644 "$SOURCE_DRC" "$OUT_DIR/drc.rpt"
install -m 0644 "$SIM_LOG" "$OUT_DIR/tinyvit_stream_safe_sim.log"
install -m 0644 "$BURST_SIM_LOG" "$OUT_DIR/lsme_v2_burst_diag_old_v2_sim.log"
install -m 0644 "$README_TEMPLATE" "$OUT_DIR/README.md"

ARTIFACTS=(
    lsme_stream_safe.bit tinyvit_stream_safe.bin tinyvit_stream_safe.elf
    tinyvit_stream_safe.mif lsme_v2_burst_diag.bin lsme_v2_burst_diag.elf
    timing_summary.rpt dsp_utilization.rpt drc.rpt
    tinyvit_stream_safe_sim.log lsme_v2_burst_diag_old_v2_sim.log README.md
)
{
    printf 'LSME-128I stream-safe remote demo package\n'
    printf 'V1 stream is the only board-validated TinyViT path in this package.\n'
    printf 'V2 cached is diagnostic-only until the target board passes the burst test.\n\n'
    (cd "$OUT_DIR" && sha256sum "${ARTIFACTS[@]}" )
} > "$OUT_DIR/BUILD_MANIFEST.txt"
(
    cd "$OUT_DIR"
    sha256sum "${ARTIFACTS[@]}" > SHA256SUMS
)

printf '已生成实板安全演示包：%s\n' "$OUT_DIR"
printf '演示上传：lsme_stream_safe.bit -> tinyvit_stream_safe.bin；诊断上传：lsme_v2_burst_diag.bin。\n'
