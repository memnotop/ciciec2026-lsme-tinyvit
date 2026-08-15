#!/usr/bin/env bash
# 生成不混入历史 V1/兼容包的最终提交目录。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/release/final_submission_v2_rmsnorm_20260813"
ARCHIVE="$ROOT/release/final_submission_v2_rmsnorm_20260813.tar.gz"
ARCHIVE_SHA="$ARCHIVE.sha256"
VERIFY="$ROOT/build/verification"
BIT="$ROOT/fpga/project/Loongson_Soc.runs/impl_1/soc_top.bit"
BASELINE_BIT="$ROOT/release/lsme_tinyvit_64lane.bit"
EXPECTED_BASELINE_SHA="fa67ca61f14bc3aa6023626861917b834baa016a996a024285e0fc63552a0a71"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "缺少必需文件：$1" >&2
        exit 1
    fi
}

require_marker() {
    local file="$1"
    local marker="$2"
    require_file "$file"
    if ! grep -Fq "$marker" "$file"; then
        echo "验证日志不完整：$file 缺少 $marker" >&2
        exit 1
    fi
}

# 防止“日志验证的是旧软件、包内却编入新软件”的静默版本漂移。
require_sources_not_newer_than() {
    local reference="$1"
    local description="$2"
    shift 2
    local newer

    newer=$(find "$@" -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' \
        -o -name '*.v' -o -name '*.vh' -o -name '*.tcl' -o -name 'Makefile' \) \
        -newer "$reference" -print -quit)
    if [[ -n "$newer" ]]; then
        echo "$description 在验证日志之后发生变化：$newer" >&2
        echo "请先重新运行 make final-regression。" >&2
        exit 1
    fi
}

require_file "$BIT"
require_file "$BASELINE_BIT"
if [[ "$(sha256sum "$BASELINE_BIT" | awk '{print $1}')" != "$EXPECTED_BASELINE_SHA" ]]; then
    echo "分赛区决赛基线 bit 的校验和不符合预期，拒绝生成比较结论。" >&2
    exit 1
fi
if find "$ROOT/rtl" "$ROOT/fpga/constraints" -type f -newer "$BIT" -print -quit | grep -q . || \
   find "$ROOT/fpga" -maxdepth 1 -type f \( -name '*.tcl' -o -name 'Makefile' \) \
       -newer "$BIT" -print -quit | grep -q .; then
    echo "RTL 或约束文件比最终 bit 更新；请先重新运行 make impl && make bitstream。" >&2
    exit 1
fi

require_marker "$VERIFY/final_v2_rmsnorm_rtl.log" "LSME_RTL_REGRESSION_PASS"
require_marker "$VERIFY/final_v2_rmsnorm_preflight_soc.log" "LSME_V2_RMSNORM_PREFLIGHT_PASS"
require_marker "$VERIFY/final_v2_rmsnorm_full_soc.log" "TINYVIT_DEMO_PASS"
require_marker "$VERIFY/final_v2_rmsnorm_remote_soc.log" "TINYVIT_V2_PASS"
require_marker "$VERIFY/final_v2_rmsnorm_impl.log" "Worst setup slack:"
require_marker "$VERIFY/final_v2_rmsnorm_bitstream.log" "Bitgen Completed Successfully"
require_sources_not_newer_than "$VERIFY/final_v2_rmsnorm_preflight_soc.log" \
    "预检源码" "$ROOT/rtl" "$ROOT/sim" "$ROOT/sdk/software/bsp" \
    "$ROOT/sdk/software/examples/lsme_v2_rmsnorm_preflight"
require_sources_not_newer_than "$VERIFY/final_v2_rmsnorm_full_soc.log" \
    "完整 TinyViT 源码" "$ROOT/rtl" "$ROOT/sim" "$ROOT/sdk/software/bsp" \
    "$ROOT/sdk/software/examples/tinyvit_demo"
require_sources_not_newer_than "$VERIFY/final_v2_rmsnorm_remote_soc.log" \
    "远程演示源码" "$ROOT/rtl" "$ROOT/sim" "$ROOT/sdk/software/bsp" \
    "$ROOT/sdk/software/examples/tinyvit_demo" \
    "$ROOT/sdk/software/examples/tinyvit_remote"

mkdir -p "$OUT/verification" "$OUT/reports"

# 每一种固件立即保存自己的 MIF，避免后续 make 覆盖 sdk/axi_ram.mif 后发生混配。
make -C "$ROOT" software
install -m 0644 "$ROOT/sdk/user-sample.bin" "$OUT/tinyvit_v2_rmsnorm_final_full.bin"
install -m 0644 "$ROOT/sdk/software/examples/tinyvit_demo/obj/tinyvit_demo.elf" \
    "$OUT/tinyvit_v2_rmsnorm_final_full.elf"
install -m 0644 "$ROOT/sdk/axi_ram.mif" "$OUT/tinyvit_v2_rmsnorm_final_full_axi_ram.mif"

make -C "$ROOT" software-compact
install -m 0644 "$ROOT/sdk/tinyvit_remote.bin" "$OUT/tinyvit_v2_rmsnorm_final_remote.bin"
install -m 0644 "$ROOT/sdk/software/examples/tinyvit_remote/obj/tinyvit_remote.elf" \
    "$OUT/tinyvit_v2_rmsnorm_final_remote.elf"
install -m 0644 "$ROOT/sdk/axi_ram.mif" "$OUT/tinyvit_v2_rmsnorm_final_remote_axi_ram.mif"

make -C "$ROOT" preflight-v2-rmsnorm
install -m 0644 "$ROOT/sdk/lsme_v2_rmsnorm_preflight.bin" "$OUT/lsme_v2_rmsnorm_preflight.bin"
install -m 0644 "$ROOT/sdk/software/examples/lsme_v2_rmsnorm_preflight/obj/lsme_v2_rmsnorm_preflight.elf" \
    "$OUT/lsme_v2_rmsnorm_preflight.elf"
install -m 0644 "$ROOT/sdk/axi_ram.mif" "$OUT/lsme_v2_rmsnorm_preflight_axi_ram.mif"
make -C "$ROOT" software

install -m 0644 "$BIT" "$OUT/lsme_v2_rmsnorm_final.bit"
install -m 0644 "$ROOT/fpga/project/Loongson_Soc.runs/impl_1/soc_top_utilization_placed.rpt" \
    "$OUT/reports/soc_top_utilization_placed.rpt"
install -m 0644 "$ROOT/fpga/project/Loongson_Soc.runs/impl_1/soc_top_timing_summary_routed.rpt" \
    "$OUT/reports/soc_top_timing_summary_routed.rpt"
install -m 0644 "$VERIFY/final_v2_rmsnorm_rtl.log" "$OUT/verification/"
install -m 0644 "$VERIFY/final_v2_rmsnorm_preflight_soc.log" "$OUT/verification/"
install -m 0644 "$VERIFY/final_v2_rmsnorm_full_soc.log" "$OUT/verification/"
install -m 0644 "$VERIFY/final_v2_rmsnorm_remote_soc.log" "$OUT/verification/"
install -m 0644 "$VERIFY/final_v2_rmsnorm_impl.log" "$OUT/verification/"
install -m 0644 "$VERIFY/final_v2_rmsnorm_bitstream.log" "$OUT/verification/"
install -m 0644 "$ROOT/tools/templates/final_v2_rmsnorm_submission_README.md" "$OUT/README.md"
install -m 0644 "$ROOT/tools/templates/final_v2_rmsnorm_submission_VALIDATION.md" "$OUT/VALIDATION.md"
install -m 0644 "$ROOT/tools/templates/final_v2_rmsnorm_submission_VIDEO_SCRIPT_60S.md" \
    "$OUT/VIDEO_SCRIPT_60S.md"
install -m 0644 "$ROOT/tools/templates/final_v2_rmsnorm_submission_RECORDING_CHECKLIST.md" \
    "$OUT/RECORDING_CHECKLIST.md"

{
    echo "# 版本沿革与可比性"
    echo
    echo "- 分赛区决赛基线：V2 Cached Macro8，实板展示记录为 1,007,062 cycles。"
    echo "- 基线 bit SHA256：$EXPECTED_BASELINE_SHA"
    echo "- 本正式包：保留上述 Macro8 GEMM，并增加 descriptor 化硬件 RMSNorm。"
    echo "- 本次正式完整固件 SoC 仿真：684,692 cycles；相对基线减少 32.01%，即 1.4708x。"
    echo "- 本次正式远程精简固件 SoC 仿真：684,654 cycles，保留相同 15 个描述符、12,864 次 MOPA、546 个宏瓦片和 192 行 RMSNorm。"
    echo "- 本包 bit SHA256：$(sha256sum "$OUT/lsme_v2_rmsnorm_final.bit" | awk '{print $1}')"
    echo "- 未改动的核心 Macro8 文件 SHA256：$(sha256sum "$ROOT/rtl/ip/lsme/lsme_gemm_v2.v" | awk '{print $1}')"
    echo "- 新增 RMSNorm 核文件 SHA256：$(sha256sum "$ROOT/rtl/ip/lsme/lsme_rmsnorm_core.v" | awk '{print $1}')"
    echo
    echo "性能比较仅使用同一 TinyViT 模型与相同定点参考。新 bit 尚需按 README 的预检流程完成现场确认，不能用历史 V1 或兼容包替代。"
} >"$OUT/LINEAGE.md"

{
    echo "LSME-TinyViT final submission manifest"
    echo "baseline_v2_macro8_bit_sha256=$EXPECTED_BASELINE_SHA"
    echo "final_bit=lsme_v2_rmsnorm_final.bit"
    echo "final_bit_sha256=$(sha256sum "$OUT/lsme_v2_rmsnorm_final.bit" | awk '{print $1}')"
    echo "preflight_bin_sha256=$(sha256sum "$OUT/lsme_v2_rmsnorm_preflight.bin" | awk '{print $1}')"
    echo "remote_bin_sha256=$(sha256sum "$OUT/tinyvit_v2_rmsnorm_final_remote.bin" | awk '{print $1}')"
    echo "full_bin_sha256=$(sha256sum "$OUT/tinyvit_v2_rmsnorm_final_full.bin" | awk '{print $1}')"
    echo "required_capability_lacc=024040bf"
    echo "required_capability_csr=024040bf"
    echo "remote_upload_offset=0x0"
    echo "preflight_marker=LSME_V2_RMSNORM_PREFLIGHT_PASS"
    echo "demo_marker=TINYVIT_V2_PASS"
    echo "full_soc_sim_cycles=684692"
    echo "remote_soc_sim_cycles=684654"
    echo "baseline_cycles=1007062"
    echo "routed_wns_ns=0.330"
    echo "routed_whs_ns=0.022"
    echo "routed_dsp48=0"
} >"$OUT/BUILD_MANIFEST.txt"

(
    cd "$OUT"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

tar -czf "$ARCHIVE" -C "$ROOT/release" "$(basename "$OUT")"
sha256sum "$ARCHIVE" >"$ARCHIVE_SHA"

echo "FINAL_SUBMISSION_PACKAGE_READY $OUT"
echo "FINAL_SUBMISSION_ARCHIVE_READY $ARCHIVE"
