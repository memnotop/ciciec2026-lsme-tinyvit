# 两版本对比与优化路径

## 1. 最终版本定位

### A. 分赛区最终版：拼音 V1 Stream

目录：`01_regional_pinyin_stream_v1/`

这是分赛区用于远程展示的稳定基线。串口使用 ASCII 拼音，DVI 仍显示输入、注意力
热图、十分类得分、预测/期望和性能计数。其核心是 LoongArch LACC 自定义指令、
4x4 INT8 外积累加 MOPA、ZA 状态、整数 Softmax、Vector Add 与描述符执行器。

`04_regional_soc_sim.log` 的样例 0 证据：

| 指标 | 数值 |
|---|---:|
| 数据/输入 | Fashion-MNIST，28x28 灰度零填充至 32x32 |
| 正确性 | `TINYVIT_DEMO_PASS`，10 个 logits 逐项一致 |
| CPU inference cycles | 1,477,854 |
| 描述符数 | 12 |
| 64 路 MOPA 次数 | 12,824 |
| 4x4 输出瓦片数 | 2,179 |
| Softmax 行数 | 256 |
| 后端 WNS/WHS | +0.274 ns / +0.037 ns |
| DSP48 | 0 |

这里的实板口径是：历史远程板以 V1 Stream 路径作为推荐与自检路径。该版本是后续
优化的正确性与演示可用性基线。

### B. 当前最终版：RGB332 CIFAR-10 双 block 安全展示版

目录：`02_current_rgb332_verified/`

当前版使用已成功启动的 RGB332-DVI 物理 bitstream，软件采用 V1 Stream 描述符
路径，以换取远程板启动确定性。它把展示对象升级为真实 32x32 RGB 图像，并将
TinyViT 扩展为两层 Transformer block；DVI 将每个 RGB332 源像素无插值放大为
8x8 像素，形成 256x256 输入预览，同时保留 8x8 Attention 热图与十分类条。

`03_current_soc_sim.log` 的样例 0 证据：

| 指标 | 数值 |
|---|---:|
| 数据/输入 | CIFAR-10，32x32x3 RGB |
| 模型工作量 | 2 个 block，64 tokens，4 heads，1,672,704 MACs |
| 正确性 | `CIFAR32_TINYVIT_STREAM_PASS`，`exact=1` |
| CPU inference cycles | 2,832,193 |
| 描述符数 | 25 |
| 64 路 MOPA 次数 | 26,136 |
| 4x4 输出瓦片数 | 4,227 |
| Softmax 行数 | 512 |
| DVI 测试 | `AXI_DVI_XAI_PASS` |

当前 bitstream 的 SHA256 为
`a4ee58f832553fa4826de91ac7cb604ff64efaeb87effa834124719d486e953e`。它来自
此前已成功启动的 RGB332-DVI 物理基线；当前 `.bin` 已完成完整 SoC 行为仿真。

## 2. 可直接放入 PPT 的差异表

| 维度 | 分赛区最终版 | 当前最终版 | 价值 |
|---|---|---|---|
| 输入展示 | Fashion-MNIST 灰度图 | CIFAR-10 32x32x3 RGB332 | 从单通道字符/服饰图升级为更直观的彩色视觉任务 |
| 模型深度 | 单 Attention block 对应 256 Softmax 行 | 双 block，对应 512 Softmax 行 | 展示更完整的 Transformer 重复结构 |
| 软件执行路径 | V1 Stream GEMM | V1 Stream GEMM | 保持已验证低风险数据路径，避免把研究候选误作实板版本 |
| 计算规模 | 12 描述符、12,824 MOPA | 25 描述符、26,136 MOPA | 当前演示包含更大真实推理工作量 |
| 可解释展示 | 输入、Attention、分类条、性能 | RGB 输入、Attention、分类条、PASS、自动轮播 | 远程录屏更易观察输入和结果随样例切换变化 |
| 正确性判据 | 10 logits 逐项一致 | 10 logits 逐项一致 | 两版都不是只验证 top-1 |
| 后端策略 | 分赛区稳定实现 | 复用已成功启动的 RGB332 物理基线 | 以实板可靠性优先于未经验证的全量重布局 |

## 3. 为什么不能直接比较两版 cycles

`1,477,854` 和 `2,832,193` 对应不同的数据集、输入通道数、模型深度、描述符数量
与 MAC 总数。当前版 cycles 更高是因为工作负载更大，不能据此宣称性能下降。

性能结论必须使用同一模型、同一量化参数、同一输入布局的消融实验。例如 V2 Cached
Macro8 与硬件 RMSNorm 的同模型周期数据，或融合 Attention 的同模型 RTL/SoC 仿真
数据。下表将“展示版本”与“技术路线”分开，保证论证成立。

## 4. 技术优化路线

```text
阶段 0  分赛区 V1 Stream
  LACC + Z/P/ZA + 4x4 INT8 MOPA + Softmax/VADD + DVI
       |
       | 复用同一 4x4 原子 MOPA，提升描述符调度和片上数据复用
       v
阶段 1  V2 Cached Macro8
  8x8 宏瓦片 + A/B BRAM resident cache + 1~8 beat AXI burst
       |
       | 将 3 个归一化阶段从 CPU 标量代码迁移为描述符算子
       v
阶段 2  V2 + 硬件 RMSNorm
  流式平方和归约 + 整数 sqrt/reciprocal + INT8 gain/requantization
       |
       | 以 FlashAttention 的 IO-aware 思路压缩 QK-Softmax-PV 中间外存流量
       v
阶段 3  融合 Attention OP5（研究候选，未纳入当前 bitstream）
  QK^T -> 片上 Score -> 原整数 Softmax -> Probability*V -> token-major Context
       |
       | 以实板稳定性优先，选择经过完整 SoC 回归的 RGB332 安全展示包
       v
当前版  RGB332 CIFAR-10 双 block 安全演示
```

### 阶段 1：V2 Cached Macro8

设计不复制 8x8 乘法阵列，而是让四个 4x4 ZA 象限组成一个 8x8 宏瓦片。A/B 在
BRAM 中驻留并通过 burst 搬运，减少 V1 每个小瓦片的访存与调度开销。已有成功展示
记录的参考周期为 `1,007,062`；相对分赛区 V1 的 `1,477,854`，在同一路线演示负载
下约减少 `31.9%`，即约 `1.468x`。此数据用于技术演进说明，使用时应注明具体的
V2 演示构建与测试条件。

### 阶段 2：硬件 RMSNorm

RMSNorm 使用逐行平方和、迭代整数平方根、共享定点倒数和 INT8 饱和写回，实现
SME 风格的 streaming/reduction 思路。V2 + RMSNorm 在同模型完整 SoC 行为仿真中
为 `684,692 cycles`，相对 `1,007,062` 的 V2 Cached 基线约 `1.471x`。它有 RTL、
SoC 仿真和实现报告，但历史远程板未完成同构的最终验证，因此不能作为当前实板版本
的功能宣称。

### 阶段 3：融合 Attention OP5

融合 Attention 用一个 64-byte 描述符完成 QK^T、整数 Softmax、Probability*V：

- Q/K/V 在片上缓存复用；S32 score 与 Q7 probability 不写回外部 SRAM；
- 输出直接采用 token-major Context，删除 CPU `merge_heads()`；
- 额外导出 64 项 attention column-sum，保持 DVI 热图；
- 算术复用已验证的 INT8 MOPA、原 Softmax ROM/LUT 和对称重量化，目标为 bit-exact。

在当前 CIFAR 双 block工作负载的 SoC 仿真中，研究候选为 `2,192,575 cycles`，
相对当前 V1 基线 `2,832,193 cycles` 降低 `22.58%`，描述符由 `25` 降至 `21`。
但其 FPGA 实现物理复用不足，未通过远程板启动验证。因此它只能作为“后续可量化
优化方向/RTL 仿真结果”，不能写为本包当前烧写版的已实测性能。

## 5. 可强调的自主 IP 创新点

1. **双层 ISA**：LoongArch LACC 低级 Z/P/ZA 操作与 64-byte 高级描述符并存；
   前者证明体系结构状态可见，后者适合 Transformer 粗粒度调度。
2. **SME 启发而非照搬**：以 Z、P、ZA、外积累加和流式归约借鉴 SME 思想，针对
   XC7A200T 的资源与 32-bit AXI 带宽实现固定 INT8 子集。
3. **DSP-free INT8 外积**：64 路 4x4x4 MOPA 采用 LUT 逻辑，两个最终展示版均有
   DSP48=0 的后端证据。
4. **端到端 Transformer 算子链**：GEMM、Softmax、VADD、RMSNorm 研究版本及
   Attention 融合研究版本覆盖 Transformer 的主要张量操作。
5. **可解释展示闭环**：Attention summary 驱动热图，十个 logits 逐项校验驱动 PASS，
   不是单独的矩阵乘测试或静态画面。

## 6. 建议的结论表述

可以说：

> 项目以分赛区实板稳定的 V1 Stream 为正确性基线，在同一 LSME-128I 架构上完成了
> V2 Cached Macro8、流式整数 RMSNorm 和 IO-aware 融合 Attention 的分阶段设计；
> 当前交付选择已经验证启动的 RGB332 CIFAR-10 双 block展示版，优先保证远程演示
> 的可靠性，同时保留可复核的后续性能优化证据。

不要说：

> 当前 RGB332 安全展示版已经在实板启用了融合 Attention，或当前版本相对分赛区版
> 的总 cycles 更低。
