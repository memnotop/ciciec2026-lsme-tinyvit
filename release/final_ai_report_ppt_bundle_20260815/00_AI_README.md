# LSME TinyViT 最终 AI 报告与 PPT 资料包

本目录只保留两个可区分、可追溯的展示版本，并附带技术演进和可引用数据。用于
生成报告、PPT、答辩稿时，应先阅读本文件，再使用 `03_version_comparison_and_optimization_path.md`
中的数据表与口径。

## 目录导航

| 目录/文件 | 内容 | 使用边界 |
|---|---|---|
| `01_regional_pinyin_stream_v1/` | 分赛区最终拼音串口 V1 Stream 展示版 | 历史实板推荐基线；Fashion-MNIST 灰度任务 |
| `02_current_rgb332_verified/` | 当前 RGB332 安全展示版 | 当前烧写组合；CIFAR-10 RGB、2-block TinyViT |
| `03_version_comparison_and_optimization_path.md` | 两版本区别、可比指标、技术演进 | 报告/PPT 的主叙事素材 |
| `04_technical_reference/` | ISA、架构、性能、融合 Attention、验证文档 | 技术细节与引用来源 |
| `05_code_and_evidence_index.md` | RTL/软件/仿真/报告的源码位置 | 需要继续追踪代码时使用 |
| `06_report_ppt_material.md` | 可直接复用的报告与 PPT 结构、表述边界 | 防止把仿真结果说成实板实测 |
| `SHA256SUMS` | 包内文件完整性校验 | 上传或归档前校验 |

## 当前可上板组合

当前版必须成对使用：

```text
02_current_rgb332_verified/00_current_rgb332_verified.bit
02_current_rgb332_verified/01_current_cifar_tinyvit_rgb332_stream.bin
```

将 `.bin` 写入 **BaseRAM** 的 `0x00000000`，然后复位 CPU。预期 UART 包含：

```text
CIFAR32_TINYVIT_BOOT_V1_STREAM
CIFAR32_TINYVIT_STREAM_PASS
```

`02_current_cifar_tinyvit_rgb332_axi_ram.mif` 只用于仿真或重新综合的 SRAM 初始化；
远程平台写入的是 `.bin`。

## 核心结论

- 分赛区版本证明了 LoongArch 自定义 LACC、64 路 INT8 MOPA、整数 Softmax、
  VADD、DVI 注意力热图及逐位校验的完整闭环。
- 当前版本在稳定物理 bitstream 上将展示升级为 32x32 RGB332 输入、CIFAR-10、
  双 Transformer block、10 类柱状图和可轮播的远程录屏界面。
- 已完成但未纳入当前可烧写版本的 V2 Cached Macro8、硬件 RMSNorm 和融合 Attention
  是技术演进证据；其中融合 Attention 的候选仅通过 RTL/SoC 仿真，尚未完成实板
  启动验证，不能写成当前实板功能。

## 重要口径

两套最终版本的模型、数据集和工作量不同。不要直接使用 `1,477,854` 与
`2,832,193` cycles 计算“当前版相对分赛区版加速/减速倍数”。可比较的是架构路线
中的同模型消融，完整说明见 `03_version_comparison_and_optimization_path.md`。
