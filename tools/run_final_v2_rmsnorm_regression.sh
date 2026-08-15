#!/usr/bin/env bash
# 对正式提交运行三层回归，并在结束时恢复默认 TinyViT MIF。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$ROOT/build/verification"
mkdir -p "$VERIFY_DIR"

restore_default_image() {
    make -C "$ROOT" software >/dev/null 2>&1 || true
}
trap restore_default_image EXIT

run_soc_sim() {
    local name="$1"
    local marker="$2"
    local log="$VERIFY_DIR/$name"

    make -C "$ROOT/fpga" sim >"$log" 2>&1
    if ! grep -Fq "$marker" "$log"; then
        echo "回归失败：$name 中缺少标记 $marker" >&2
        tail -n 80 "$log" >&2
        exit 1
    fi
}

echo "[1/4] RTL 回归"
make -C "$ROOT" rtl-test >"$VERIFY_DIR/final_v2_rmsnorm_rtl.log" 2>&1
grep -Fq "LSME_RTL_REGRESSION_PASS" "$VERIFY_DIR/final_v2_rmsnorm_rtl.log"

echo "[2/4] V2 Cached Macro8 + RMSNorm 预检 SoC 仿真"
make -C "$ROOT" preflight-v2-rmsnorm
run_soc_sim "final_v2_rmsnorm_preflight_soc.log" "LSME_V2_RMSNORM_PREFLIGHT_PASS"
grep -Fq "PREFLIGHT_CAP lacc=024040bf csr=024040bf" \
    "$VERIFY_DIR/final_v2_rmsnorm_preflight_soc.log"

echo "[3/4] 完整 TinyViT 位精确 SoC 仿真"
make -C "$ROOT" software
run_soc_sim "final_v2_rmsnorm_full_soc.log" "TINYVIT_DEMO_PASS"
grep -Fq "LSME_DEMO_VERIFY logits=10/10 bit_exact=yes classification=yes rmsnorm_rows=192" \
    "$VERIFY_DIR/final_v2_rmsnorm_full_soc.log"

echo "[4/4] 远程演示精简固件 SoC 仿真"
make -C "$ROOT" software-compact
run_soc_sim "final_v2_rmsnorm_remote_soc.log" "TINYVIT_V2_PASS"
grep -Fq "V2_CAP 024040bf 024040bf" \
    "$VERIFY_DIR/final_v2_rmsnorm_remote_soc.log"

echo "FINAL_V2_RMSNORM_REGRESSION_PASS"
