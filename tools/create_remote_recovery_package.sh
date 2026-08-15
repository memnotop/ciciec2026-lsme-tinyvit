#!/usr/bin/env bash
# 生成远程 FPGA 的已知可启动恢复包。
#
# 这个脚本刻意不重新实现 RTL，也不重新编译固件。它只复制已经完成过
# 远程实板自检的 V1 流式演示产物，并先校验其固定 SHA-256，以免把新的
# V2 + RMSNorm 位流误当作恢复版本发布。

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_DIR="$ROOT_DIR/release/remote_demo_zh_20260726"
OUT_DIR=${1:-"$ROOT_DIR/release/remote_recovery_20260813"}

SOURCE_BIT="$SOURCE_DIR/lsme_tinyvit_xai_pinyin_stream_v1.bit"
SOURCE_BIN="$SOURCE_DIR/lsme_tinyvit_xai_pinyin_stream_v1.bin"
SOURCE_ELF="$SOURCE_DIR/tinyvit_demo_pinyin_stream_v1.elf"
SOURCE_SELFTEST="$SOURCE_DIR/lsme_selftest_stream.bin"
SOURCE_SIM_LOG="$SOURCE_DIR/tinyvit_pinyin_stream_v1_simulate.log"
README_TEMPLATE="$ROOT_DIR/tools/templates/remote_recovery_README.md"

EXPECTED_BIT_SHA=6657d382705532f503a17c45e8258a3c1e58b994ee14b80cc995cb9bc7f1414a
EXPECTED_BIN_SHA=9e1ae401a79a9eb00a9966be4fdb60a316927b920f8acb60a57072c7ff761e77

for artifact in "$SOURCE_BIT" "$SOURCE_BIN" "$SOURCE_ELF" \
                "$SOURCE_SELFTEST" "$SOURCE_SIM_LOG" "$README_TEMPLATE"; do
    if [[ ! -f "$artifact" ]]; then
        printf '缺少恢复源文件：%s\n' "$artifact" >&2
        exit 1
    fi
done

if [[ "$(sha256sum "$SOURCE_BIT" | awk '{print $1}')" != "$EXPECTED_BIT_SHA" ]]; then
    printf '恢复 bitstream 的 SHA-256 不符合已验证基线，停止打包。\n' >&2
    exit 1
fi
if [[ "$(sha256sum "$SOURCE_BIN" | awk '{print $1}')" != "$EXPECTED_BIN_SHA" ]]; then
    printf '恢复固件的 SHA-256 不符合已验证基线，停止打包。\n' >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
install -m 0644 "$SOURCE_BIT" "$OUT_DIR/lsme_remote_recovery_stream_v1.bit"
install -m 0644 "$SOURCE_BIN" "$OUT_DIR/lsme_remote_recovery_stream_v1.bin"
install -m 0644 "$SOURCE_ELF" "$OUT_DIR/tinyvit_remote_recovery_stream_v1.elf"
install -m 0644 "$SOURCE_SELFTEST" "$OUT_DIR/lsme_remote_recovery_selftest.bin"
install -m 0644 "$SOURCE_SIM_LOG" "$OUT_DIR/tinyvit_remote_recovery_stream_v1_sim.log"
install -m 0644 "$SOURCE_DIR/timing_summary.rpt" "$OUT_DIR/timing_summary.rpt"
install -m 0644 "$SOURCE_DIR/drc.rpt" "$OUT_DIR/drc.rpt"
install -m 0644 "$SOURCE_DIR/dsp_utilization.rpt" "$OUT_DIR/dsp_utilization.rpt"
install -m 0644 "$README_TEMPLATE" "$OUT_DIR/README.md"

{
    printf 'LSME remote known-good recovery package\n'
    printf 'This package intentionally contains the historical board-validated V1 stream baseline.\n'
    printf 'Do not claim it as V2 + RMSNorm hardware evidence.\n\n'
    (cd "$OUT_DIR" && sha256sum \
        lsme_remote_recovery_stream_v1.bit \
        lsme_remote_recovery_stream_v1.bin \
        tinyvit_remote_recovery_stream_v1.elf \
        lsme_remote_recovery_selftest.bin \
        tinyvit_remote_recovery_stream_v1_sim.log \
        timing_summary.rpt drc.rpt dsp_utilization.rpt)
} > "$OUT_DIR/BUILD_MANIFEST.txt"

(
    cd "$OUT_DIR"
    sha256sum \
        lsme_remote_recovery_stream_v1.bit \
        lsme_remote_recovery_stream_v1.bin \
        tinyvit_remote_recovery_stream_v1.elf \
        lsme_remote_recovery_selftest.bin \
        tinyvit_remote_recovery_stream_v1_sim.log \
        timing_summary.rpt drc.rpt dsp_utilization.rpt > SHA256SUMS
)

printf '已生成已知可启动恢复包：%s\n' "$OUT_DIR"
