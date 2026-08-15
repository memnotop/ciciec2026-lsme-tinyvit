# 报告与 PPT 素材

## 建议 PPT 结构（10 页）

1. **问题与目标**：在 LoongArch32R + XC7A200T 上实现可运行 Transformer 的自主
   INT8 矩阵扩展，而不是孤立 GEMM IP。
2. **总体架构**：CPU/LACC/CDC/LSME/AXI/DVI 五层；引用
   `04_technical_reference/lsme_architecture.md`。
3. **SME 启发的状态与 ISA**：Z、P、ZA、SMOPA、EXEC/WAIT；引用
   `04_technical_reference/lsme_isa.md`。
4. **4x4 MOPA 与 8x8 Macro8**：说明“4x4 是原子算术粒度，8x8 是调度粒度”。
5. **分赛区最终展示**：放入拼音 UART 日志中的 `TINYVIT_DEMO_PASS`、DVI 截图和
   1,477,854 cycles/12,824 MOPA/12 descriptors。
6. **当前 RGB332 展示**：放入当前 DVI 截图和 `CIFAR32_TINYVIT_STREAM_PASS`；强调
   32x32 RGB、双 block、1,672,704 MACs、可轮播。
7. **优化路线**：使用 `03_version_comparison_and_optimization_path.md` 的阶段图。
8. **V2/RMSNorm/融合 Attention 技术细节**：用“已完成的分阶段研发”表述，标记证据
   来源为 RTL/SoC 仿真或历史实板，不能混用。
9. **正确性、PPA 和工程取舍**：10 logits bit-exact、DSP48=0、WNS/WHS，及以稳定
   bitstream作为当前交付的原因。
10. **结论与后续**：强调可运行、可解释、可扩展；下一步是通过实板验证的 OP5 融合。

## 可直接引用的数据

| 项目 | 数值 | 来源与表述 |
|---|---:|---|
| 分赛区样例周期 | 1,477,854 | `01.../04_regional_soc_sim.log`，完整 SoC 仿真 |
| 分赛区 MOPA/描述符 | 12,824 / 12 | 同上 |
| 当前样例周期 | 2,832,193 | `02.../03_current_soc_sim.log`，完整 SoC 仿真 |
| 当前工作量 | 1,672,704 MACs、25 descriptors | 同上 |
| 当前融合候选周期 | 2,192,575 | 仅 RTL/SoC 研究结果，未实板验证 |
| 融合候选降幅 | 22.58% | 同一 CIFAR 双 block V1 基线对比，不可说成实板测得 |
| 分赛区 PPA | 43,787 LUT、19,919 FF、DSP48=0、WNS/WHS +0.274/+0.037 ns | `01.../05/06` 报告 |

## 推荐图示

- **结构图**：LoongArch CPU -> LACC -> CDC -> LSME EXEC -> MOPA/Softmax/VADD -> AXI ->
  SRAM，DVI 从软件 MMIO 接收输入/attention/logits。
- **数据流图**：Q/K/V -> QK^T -> Softmax -> PV -> Context；将“片上 score/prob”和
  “attention column sum”标为融合 Attention 的未来优化。
- **演进图**：V1 Stream -> V2 Cached Macro8 -> HW RMSNorm -> OP5 Fused Attention；
  对每阶段附证据标签：实板、SoC 仿真、RTL 仿真或研究候选。

## 安全表述模板

> 本项目当前远程展示版采用已验证物理 bitstream，在 RGB CIFAR-10 双 block TinyViT
> 上完成了从输入预览、注意力热图、十分类得分到逐 logits 校验的端到端闭环。体系
> 结构以 SME 的 Z/P/ZA 与外积累加思想为参考，落地为 LoongArch 自定义 LACC 指令
> 和整数描述符执行器。V2 Cached Macro8、硬件 RMSNorm 与融合 Attention 形成逐级
> 可量化的后续优化路线；其中未完成实板验证的结果明确标注为仿真研究，不混同于
> 当前展示版实测。
