#!/usr/bin/env bash
# 生成“历史实板验证 V2 bit + 描述符张量视图零拷贝固件”的远程测试包。
# 该脚本刻意不触发综合、实现或 bitstream 生成，避免将未验证的物理配置
# 混入远程演示。硬件配置必须逐字节来自区域赛已成功展示的原始 bit。

set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT_DIR/release/v2_zerocopy_remote_test_20260814"}
VERIFY_DIR="$ROOT_DIR/build/verification"
SAMPLE0_LOG="$VERIFY_DIR/v2_zerocopy_final_sample0_soc.log"
SAMPLE1_LOG="$VERIFY_DIR/v2_zerocopy_final_sample1_soc.log"
SAMPLE7_LOG="$VERIFY_DIR/v2_zerocopy_final_sample7_soc.log"
PROBE_LOG="$VERIFY_DIR/v2_zerocopy_probe_soc.log"

SOURCE_BIT="$ROOT_DIR/release/lsme_tinyvit_64lane.bit"
SOURCE_BIN="$ROOT_DIR/sdk/tinyvit_v2_compat.bin"
SOURCE_ELF="$ROOT_DIR/sdk/software/examples/tinyvit_v2_compat/obj/tinyvit_v2_compat.elf"
SOURCE_MIF="$ROOT_DIR/sdk/axi_ram.mif"
PROBE_BIN="$ROOT_DIR/sdk/lsme_v2_compat_boot_probe.bin"
PROBE_ELF="$ROOT_DIR/sdk/software/examples/lsme_v2_compat_boot_probe/obj/lsme_v2_compat_boot_probe.elf"

EXPECTED_BIT_SHA=fa67ca61f14bc3aa6023626861917b834baa016a996a024285e0fc63552a0a71
EXPECTED_BIN_SHA=551ed47610376c8b3a59a456385abe742ae51f8cfd03405662b11cb902b9d7a5

for artifact in "$SOURCE_BIT" "$SOURCE_BIN" "$SOURCE_ELF" "$SOURCE_MIF" \
                "$PROBE_BIN" "$PROBE_ELF" "$SAMPLE0_LOG" "$SAMPLE1_LOG" \
                "$SAMPLE7_LOG" "$PROBE_LOG"; do
    [[ -f "$artifact" ]] || {
        printf '缺少零拷贝测试包所需文件：%s\n' "$artifact" >&2
        exit 1
    }
done

if [[ "$(sha256sum "$SOURCE_BIT" | awk '{print $1}')" != "$EXPECTED_BIT_SHA" ]]; then
    printf '历史已验证 V2 bit 的 SHA-256 不匹配，停止打包。\n' >&2
    exit 1
fi
if [[ "$(sha256sum "$SOURCE_BIN" | awk '{print $1}')" != "$EXPECTED_BIN_SHA" ]]; then
    printf '零拷贝固件不是已完成最终回归的固定版本，停止打包。\n' >&2
    exit 1
fi
for marker in TINYVIT_BOOT_V2_ZEROCOPY_SW_RMSNORM \
              'V2Z_RESULT expected=0 predicted=0 exact=1' \
              'V2Z_METRIC cycles=825578' \
              TINYVIT_V2_ZEROCOPY_PASS; do
    grep -Fq "$marker" "$SAMPLE0_LOG" || {
        printf '最终 SoC 仿真日志缺少标记：%s\n' "$marker" >&2
        exit 1
    }
done
for marker in 'V2Z_RESULT expected=1 predicted=1 exact=1' \
              'V2Z_METRIC cycles=828076' \
              TINYVIT_V2_ZEROCOPY_PASS; do
    grep -Fq "$marker" "$SAMPLE1_LOG" || {
        printf '样例 1 SoC 仿真日志缺少标记：%s\n' "$marker" >&2
        exit 1
    }
done
for marker in 'V2Z_RESULT expected=7 predicted=7 exact=1' \
              'V2Z_METRIC cycles=823715' \
              TINYVIT_V2_ZEROCOPY_PASS; do
    grep -Fq "$marker" "$SAMPLE7_LOG" || {
        printf '样例 7 SoC 仿真日志缺少标记：%s\n' "$marker" >&2
        exit 1
    }
done
for marker in 'V2C_PROBE lacc=02404088 csr=0240409f' \
              LSME_V2_COMPAT_BOOT_PROBE_PASS; do
    grep -Fq "$marker" "$PROBE_LOG" || {
        printf '启动 probe SoC 仿真日志缺少标记：%s\n' "$marker" >&2
        exit 1
    }
done

mkdir -p "$OUT_DIR"
install -m 0644 "$SOURCE_BIT" "$OUT_DIR/lsme_v2_zerocopy_known_good.bit"
install -m 0644 "$SOURCE_BIN" "$OUT_DIR/tinyvit_v2_zerocopy.bin"
install -m 0644 "$SOURCE_ELF" "$OUT_DIR/tinyvit_v2_zerocopy.elf"
install -m 0644 "$SOURCE_MIF" "$OUT_DIR/tinyvit_v2_zerocopy.mif"
install -m 0644 "$PROBE_BIN" "$OUT_DIR/lsme_v2_compat_boot_probe.bin"
install -m 0644 "$PROBE_ELF" "$OUT_DIR/lsme_v2_compat_boot_probe.elf"
install -m 0644 "$SAMPLE0_LOG" "$OUT_DIR/final_sample0_soc_sim.log"
install -m 0644 "$SAMPLE1_LOG" "$OUT_DIR/final_sample1_soc_sim.log"
install -m 0644 "$SAMPLE7_LOG" "$OUT_DIR/final_sample7_soc_sim.log"
install -m 0644 "$PROBE_LOG" "$OUT_DIR/boot_probe_soc_sim.log"

cat > "$OUT_DIR/README.md" <<'EOF'
# V2 描述符张量视图零拷贝：远程测试包

这是当前唯一建议尝试的优化组合。它将**已实板成功展示**的区域赛 V2 cached
原始 bit 与新的零拷贝软件配对；没有使用此前无 UART 输出的重建 bit 或硬件
RMSNorm bit。

## 上传顺序

1. FPGA 配置区上传 `lsme_v2_zerocopy_known_good.bit`。
2. 等待配置完成；在 BaseRAM 区将 `lsme_v2_compat_boot_probe.bin` 写入偏移
   `0x00000000`，然后复位。UART 必须出现：

   ```text
   LSME_V2_COMPAT_BOOT_PROBE_PASS
   ```

3. 保持同一个 `.bit`，将 `tinyvit_v2_zerocopy.bin` 写入**同一 BaseRAM 偏移
   `0x00000000`**，再复位。
4. UART 依次应出现：

   ```text
   TINYVIT_BOOT_V2_ZEROCOPY_SW_RMSNORM
   V2Z_CAP lacc=02404088 csr=0240409f
   V2Z_RESULT expected=0 predicted=0 exact=1
   V2Z_METRIC cycles=825578 ... speedup_vs_v2=1.220x
   TINYVIT_V2_ZEROCOPY_PASS
   ```

5. DVI 应显示输入图、8×8 注意力热图、十类分数与正确状态。SW[3:0] 选择样例；
   SW[15] 打开后每 1.8 秒自动轮播。

网页上传偏移应填 `0x00000000`；`0x1c000000` 是 CPU 链接地址，不能填为上传偏移。

## 这次优化做了什么

QKV 线性层的每个 token 原本就是 `[Q(32B), K(32B), V(32B)]`。旧软件把它复制到
三个 head-major 缓冲区，注意力输出再复制回 token-major context。新路径使用 V2
描述符的 `row_stride` / `batch_stride` 把同一片 QKV 内存解释为四个 head 的视图，
并让 AV GEMM 直接写入后续投影层需要的 context 布局。

因此没有改变模型、量化、GEMM、Softmax 或硬件 bit；消除的是 CPU 端 Q/K/V 重排和
head 合并。该思路对应 SME 中“由寄存器形状/步长描述张量视图，而非搬运重排”的数据
布局思想。

## 已完成的验证边界

- bit：该文件 SHA-256 固定为历史实板已验证值；本包未重建 FPGA bit。
- 同一旧 V2 RTL 的完整 SoC 仿真：最终 bin 在样例 0 得到 `exact=1`、
  `825,578 cycles`、并执行 DVI 发布。
- 同一候选程序还已在样例 1、7 通过 `exact=1`，周期分别为 828,076、823,715。
- 受控 A/B（仅关闭零拷贝开关）样例 0 为 1,007,063 cycles；优化版为
  825,578 cycles，减少 181,485 cycles（18.02%，1.2198×）。

上述周期为完整 SoC 仿真结果；远程录制应以 UART/DVI 的真实运行证明系统可启动和
交互，不能把仿真周期说成现场测得周期。
EOF

cat > "$OUT_DIR/VALIDATION.md" <<'EOF'
# 可核查验证记录

| 项目 | 结果 |
|---|---:|
| 历史 V2 cached 基线（样例 0） | 1,007,063 cycles |
| 描述符张量视图零拷贝（样例 0） | 825,578 cycles |
| 节省 | 181,485 cycles / 18.02% |
| 相对 V2 基线 | 1.2198× |
| 相对 V1 stream（1,827,549） | 2.2137× |
| 描述符 / MOPA / macro tiles / Softmax rows | 12 / 12,864 / 546 / 256 |
| 样例 0、1、7 | 预测正确，10 个 logits 逐位一致 |
| bit SHA-256 | `fa67ca61f14bc3aa6023626861917b834baa016a996a024285e0fc63552a0a71` |
| 最终 bin SHA-256 | `551ed47610376c8b3a59a456385abe742ae51f8cfd03405662b11cb902b9d7a5` |

引擎的硬件工作量计数保持不变是符合预期的：优化减少的是 CPU 对中间张量的搬运，
不是改变矩阵乘法或降低精度。
EOF

cat > "$OUT_DIR/VIDEO_SCRIPT_60S.md" <<'EOF'
# 60 秒录制建议

| 时间 | 画面 | 口播重点 |
|---|---|---|
| 0–8 秒 | 上传原始 V2 bit 后运行 probe，出现 PASS | “先证明历史验证的 64 路 V2 cached 硬件、CPU、UART 与 LACC ABI 都正常。” |
| 8–18 秒 | 写入零拷贝 bin，显示启动能力字和 ZC_VIEW | “这里把 QKV 当作四个带步长的张量视图，不再由 CPU 做三次重排和一次 head 合并。” |
| 18–34 秒 | DVI 输入、热图、十类分数、PASS；切换一次 SW[3:0] | “图像、注意力热图和分类分数都来自本次完整 TinyViT 推理。” |
| 34–46 秒 | UART 的 `V2Z_RESULT` 与 `V2Z_METRIC` | “分类正确，十个量化 logits 逐位一致；同一模型、同一硬件下周期从 1,007,063 降到 825,578。” |
| 46–56 秒 | 展示 VALIDATION 表 | “节省 18.02%，相对分赛区决赛 V2 为 1.2198 倍，同时仍保留 12,864 次 INT8 MOPA。” |
| 56–60 秒 | 打开 SW[15] 自动轮播或回到 DVI PASS | “优化不靠更改模型或精度，而是将 SME 风格的张量布局描述落实到 V2 描述符。” |

录像时只使用本目录的 `.bit` 与 `.bin`；若 probe 不通过，停止，不要继续写完整推理 bin。
EOF

{
    printf '# 位流来源与边界\n\n'
    printf -- '- `lsme_v2_zerocopy_known_good.bit` 是 `release/lsme_tinyvit_64lane.bit` 的逐字节副本。\n'
    printf -- '- SHA-256：`%s`。\n' "$EXPECTED_BIT_SHA"
    printf -- '- 该 bit 是用户已成功展示、周期约 1,007,062 的区域赛 V2 cached macro8 原始文件。\n'
    printf -- '- 本包没有调用实现或 bitstream 生成流程；因此不会携带此前导致无输出的重建/RMSNorm\n'
    printf -- '  物理配置。\n'
    printf -- '- 固件的三处 RMSNorm 为旧 V2 ABI 兼容的软件定点回退；不要将本包表述为“硬件 RMSNorm”。\n'
} > "$OUT_DIR/LINEAGE.md"

ARTIFACTS=(
    lsme_v2_zerocopy_known_good.bit
    tinyvit_v2_zerocopy.bin
    tinyvit_v2_zerocopy.elf
    tinyvit_v2_zerocopy.mif
    lsme_v2_compat_boot_probe.bin
    lsme_v2_compat_boot_probe.elf
    boot_probe_soc_sim.log
    final_sample0_soc_sim.log
    final_sample1_soc_sim.log
    final_sample7_soc_sim.log
    README.md
    VALIDATION.md
    VIDEO_SCRIPT_60S.md
    LINEAGE.md
)

{
    printf 'LSME-128I V2 descriptor tensor-view zero-copy remote test package\n'
    printf 'Hardware bit: historical board-validated V2 cached macro8.\n'
    printf 'Firmware: V2 GEMM/Softmax/VADD + software RMSNorm + zero-copy head layout.\n'
    printf 'Probe marker: LSME_V2_COMPAT_BOOT_PROBE_PASS\n'
    printf 'Demo marker: TINYVIT_V2_ZEROCOPY_PASS\n'
    printf 'Do not use or substitute a rebuilt/RMSNorm bitstream.\n\n'
    (cd "$OUT_DIR" && sha256sum "${ARTIFACTS[@]}")
} > "$OUT_DIR/BUILD_MANIFEST.txt"

(
    cd "$OUT_DIR"
    sha256sum "${ARTIFACTS[@]}" BUILD_MANIFEST.txt > SHA256SUMS
)

printf '已生成 V2 描述符张量视图零拷贝测试包：%s\n' "$OUT_DIR"
