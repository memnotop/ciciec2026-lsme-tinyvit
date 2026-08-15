# LSME-128I TinyViT

面向 LoongArch32R 与 XC7A200T 的自主 INT8 AI 加速 IP。项目不把 FPGA 当作单一
矩阵乘盒：CPU 通过自定义 LACC 指令访问 Z 向量、P 谓词和 ZA 矩阵累加状态，再用
64-byte 描述符运行 GEMM、整数 Softmax、VADD 与 TinyViT 推理；DVI 同步显示输入、
Attention 热图、十分类得分和逐 logits 校验结果。

30 秒内可了解的重点：

- **SME 启发**：用 Z/P/ZA、INT8 外积累加和流式归约借鉴 Arm SME 思路，但不追求
  二进制兼容，范围收敛到适合 Artix-7 的整数子集。
- **64 路 MOPA**：4x4x4 是原子外积瓦片；V2 研究路径将四个 ZA 象限调度为 8x8
  Macro8，并使用片上 A/B 缓存和 AXI burst。
- **端到端展示**：当前安全版为 CIFAR-10 32x32 RGB、双 Transformer block；完整
  SoC 仿真得到 `CIFAR32_TINYVIT_STREAM_PASS`，10 个 logits 逐项一致。
- **工程边界**：当前可上板包固定使用已验证的 RGB332 bitstream 和 V1 Stream 固件。
  V2 Cached、硬件 RMSNorm 与融合 Attention 是已保留的技术演进/仿真研究，不应写成
  当前实板已启用功能。

## 当前演示

唯一推荐的远程板组合位于：

```text
release/final_ai_report_ppt_bundle_20260815/
  02_current_rgb332_verified/00_current_rgb332_verified.bit
  02_current_rgb332_verified/01_current_cifar_tinyvit_rgb332_stream.bin
```

将 `.bin` 写到 **BaseRAM `0x00000000`**，复位 CPU。UART 应出现：

```text
CIFAR32_TINYVIT_BOOT_V1_STREAM
CIFAR32_TINYVIT_STREAM_PASS
```

同一资料包还包括分赛区拼音 V1 最终版、两版本差异、性能口径、报告/PPT 素材、
ISA/架构文档与 SHA256 校验。首先阅读：
[AI 资料包说明](release/final_ai_report_ppt_bundle_20260815/00_AI_README.md)。

## 架构

```text
LoongArch32R CPU
  -> LACC custom instruction / CDC
  -> LSME descriptor engine
  -> Z / P / ZA state + 64-lane INT8 MOPA
  -> AXI master -> BaseRAM / ExtRAM

CPU -> DVI MMIO -> RGB input + attention heatmap + class scores + PASS
```

核心源码：

- `rtl/ip/lsme/`：MOPA、Softmax、RMSNorm、AXI、CSR 与状态机。
- `rtl/ip/open-la500/`：LoongArch LACC 指令接入。
- `sdk/software/examples/cifar_tinyvit_demo/`：当前 RGB TinyViT 软件调度和参考 logits。
- `rtl/ip/DVI/axi_dvi.v`：800x600 RGB332 DVI 仪表盘。
- `fpga/fused_attention/`：融合 Attention OP5 研究 RTL。
- `doc/`：架构、ISA、性能、验证与融合 Attention 说明。

## 验证与构建

已归档的当前 SoC 证据：

```text
1,672,704 MACs, 25 descriptors, 26,136 MOPA, 2,832,193 cycles
CIFAR32_TINYVIT_STREAM_PASS
```

常用命令：

```bash
make rtl-test
make software-cifar
make sim-rgb332-baseline-dvi
```

完整 FPGA 实现还需要 Vivado、LoongArch 交叉工具链和比赛基础工程中的受控 IP/参考
检查点；它们不提交到 Git，以避免仓库包含数 GB 的缓存和工具链。可综合 RTL、脚本、
软件、仿真和最终展示资料均在本仓库。

## 版本与引用边界

性能数字必须注明来源。分赛区 Fashion-MNIST 与当前 CIFAR-10 双 block工作量不同，
不能直接比较其端到端 cycles。V2/RMSNorm/融合 Attention 的同模型消融与“实板/SoC
仿真/RTL 研究”边界见：
[版本对比与优化路径](release/final_ai_report_ppt_bundle_20260815/03_version_comparison_and_optimization_path.md)。
