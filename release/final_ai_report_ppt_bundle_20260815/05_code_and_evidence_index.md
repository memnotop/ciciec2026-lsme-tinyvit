# 源码与证据索引

本资料包保留最终二进制和报告副本；完整可编辑源码仍位于本仓库根目录。以下路径相对
仓库根目录 `ciciec2026_lsme_tinyvit/`。

## 当前安全展示版

| 主题 | 文件 | 说明 |
|---|---|---|
| 当前应用入口 | `sdk/software/examples/cifar_tinyvit_demo/main.c` | UART 阶段标记、样例选择、DVI 发布、PASS 判据 |
| 当前推理运行时 | `sdk/software/examples/cifar_tinyvit_demo/cifar_tinyvit_runtime.c` | 2-block TinyViT、描述符构造、整数参考比对 |
| 模型参数与样例 | `sdk/software/examples/cifar_tinyvit_demo/cifar_tinyvit_model.h` | CIFAR-10 INT8 参数、参考 logits、RGB332 预览 |
| LSME 软件 ABI | `sdk/software/bsp/include/lsme.h` | 描述符字段、操作码、MMIO、非缓存地址转换 |
| DVI 驱动 | `sdk/software/bsp/drivers/dvi.c` | 原子发布输入、热图、分数和指标 |
| RGB332 DVI RTL | `rtl/ip/DVI/axi_dvi.v` | 800x600 组合光栅器、256 色输入预览、热图与分类条 |
| 当前完整 SoC 证据 | `fpga/build/rgb332_baseline_firmware_rebuild_sim_20260815.log` | `CIFAR32_TINYVIT_STREAM_PASS` |
| DVI 单元证据 | `build/verilator/rgb332_recovery_dvi_20260815_retry/` | `AXI_DVI_XAI_PASS` |

## LSME 自主 IP 核心

| 层次 | 文件 | 说明 |
|---|---|---|
| 自定义指令接入 | `../技术数据/.../rtl/ip/open-la500/id_stage.v`、`lacc_core.v` | 解码 LACC 前缀，向加速器发送命令 |
| 跨时钟域 | `../技术数据/.../rtl/ip/lsme/lsme_lacc_cdc.v` | CPU 域与 50 MHz 系统域的 toggle 请求/响应 |
| 体系结构状态 | `../技术数据/.../rtl/ip/lsme/lsme_core.v` | 8 个 Z、4 个 P、4 个 ZA、低级操作与宏瓦片接口 |
| 原子算术 | `../技术数据/.../rtl/ip/lsme/lsme_mopa_core.v` | 16/32/64 路有符号 INT8 外积累加 |
| V2 缓存 GEMM | `../技术数据/.../rtl/ip/lsme/lsme_gemm_v2.v` | 8x8 Macro8、A/B BRAM 缓存、burst AXI |
| 整数 Softmax | `rtl/ip/lsme/lsme_softmax_core.v` | row-max、指数 LUT、倒数 LUT、Q7 输出 |
| 描述符执行器 | `../技术数据/.../rtl/ip/lsme/lsme_exec_engine.v` | GEMM、Softmax、VADD 的高层调度 |
| AXI 主机 | `../技术数据/.../rtl/ip/lsme/lsme_axi_master.v` | 单 outstanding、单字与 burst 传输 |

`../技术数据/...` 的完整展开路径为：
`/home/liumingjian/mloongson/技术数据/ciciec2026_lsme_tinyvit-submit/ciciec2026_lsme_tinyvit/`。

## 研究型融合 Attention

| 文件 | 内容 | 当前证据边界 |
|---|---|---|
| `fpga/fused_attention/lsme_fused_attention_core.v` | QK-Softmax-PV 片上融合控制、score SRAM、Context 直写 | 单元/SoC 仿真通过 |
| `fpga/fused_attention/lsme_softmax_score_sram.v` | score SRAM 直接读取的逐元素 Softmax | 位精确算法复用 |
| `fpga/fused_attention/lsme_exec_engine.v` | OP5 解码、AXI/MOPA owner 仲裁 | 未成为当前实板交付 |
| `fpga/fused_attention/lsme_exec_fused_attention_tb.v` | 描述符级与融合输出回归 | 回归通过 |
| `doc/fused_attention_design.md` | 架构、ABI、数学语义和学术定位 | 可用于未来方案说明 |

研究候选 bitstream 不应从 `fpga/project_rgb332_fused_attention_shared_force_incremental/`
目录取用。其布局布线未达到实板交付标准，已明确排除在本资料包之外。

## 二进制证据

- 分赛区版本的 bit/bin/mif/ELF、仿真日志、时序和 DSP 报告在
  `01_regional_pinyin_stream_v1/`。
- 当前版本的 bit/bin/mif/仿真日志在 `02_current_rgb332_verified/`。
- 所有包内文件由 `SHA256SUMS` 固定；先执行 `sha256sum -c SHA256SUMS` 再上传。
