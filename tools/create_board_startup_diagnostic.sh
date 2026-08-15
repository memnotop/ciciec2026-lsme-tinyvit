#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/release/board_startup_diagnostic_20260813"
BASE="$ROOT/../技术数据/ciciec2026_lsme_tinyvit-submit/ciciec2026_lsme_tinyvit"
KNOWN_BIT="$BASE/release/lsme_tinyvit_64lane.bit"
REBUILT_BASELINE_BIT="$ROOT/fpga/project_regional_baseline_rebuild/Regional_V2_Baseline_Rebuild.runs/impl_1/soc_top.bit"
CANDIDATE_BIT="$ROOT/release/final_submission_v2_rmsnorm_20260813/lsme_v2_rmsnorm_final.bit"

if [[ ! -f "$KNOWN_BIT" ]]; then
    printf 'missing known-good regional bit: %s\n' "$KNOWN_BIT" >&2
    exit 1
fi
if [[ ! -f "$REBUILT_BASELINE_BIT" ]]; then
    printf 'missing rebuilt visible-source baseline bit: %s\n' "$REBUILT_BASELINE_BIT" >&2
    exit 1
fi
if [[ ! -f "$CANDIDATE_BIT" ]]; then
    printf 'missing optimized candidate bit: %s\n' "$CANDIDATE_BIT" >&2
    exit 1
fi

make -C "$ROOT" boot-heartbeat \
    LA32RSOC_WINDOWS_HOME="$ROOT"

mkdir -p "$OUT"
cp "$KNOWN_BIT" "$OUT/regional_v2_known_good.bit"
cp "$REBUILT_BASELINE_BIT" "$OUT/regional_v2_rebuilt_visible_source.bit"
cp "$CANDIDATE_BIT" "$OUT/optimized_v2_rmsnorm_candidate.bit"
cp "$ROOT/sdk/lsme_boot_heartbeat.bin" "$OUT/lsme_boot_heartbeat.bin"
cp "$ROOT/sdk/software/examples/lsme_boot_heartbeat/obj/lsme_boot_heartbeat.elf" \
   "$OUT/lsme_boot_heartbeat.elf"
cp "$ROOT/tools/board_startup_diagnostic_README.md" "$OUT/README.md"

(cd "$OUT" && sha256sum regional_v2_known_good.bit regional_v2_rebuilt_visible_source.bit \
    optimized_v2_rmsnorm_candidate.bit \
    lsme_boot_heartbeat.bin > SHA256SUMS)
tar -C "$ROOT/release" -czf "$ROOT/release/board_startup_diagnostic_20260813.tar.gz" \
    board_startup_diagnostic_20260813
sha256sum "$ROOT/release/board_startup_diagnostic_20260813.tar.gz" \
    > "$ROOT/release/board_startup_diagnostic_20260813.tar.gz.sha256"

printf 'created %s\n' "$OUT"
