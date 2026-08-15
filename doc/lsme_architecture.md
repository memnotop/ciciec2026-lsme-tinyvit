# LSME-128I V2 架构与设计取舍

## 1. 目标

LSME-128I 的目标不是复刻完整 Arm SVE/SME，而是在现有 LoongArch32R 教学 SoC 和 XC7A200T 上实现一个可以真正运行 Transformer 的小型矩阵扩展：

- 有可见的 Z/P/ZA 体系结构状态和自定义指令，而不是单一 MMIO 计算盒；
- 能处理不同尺寸、转置、batch 和尾块，而不是固定 4×4 评测任务；
- 覆盖 GEMM、Softmax、RMSNorm、量化、偏置、ReLU 和向量残差等 AI 关键环节；
- 具备片上缓存、burst 传输、参数化并行度和分解性能计数器；
- 不使用 DSP48，并满足板上 50 MHz 时序。

## 2. 从 SME 借鉴什么

本设计借鉴 SME 的三项思想：

1. Z 向量寄存器保存流式操作数；
2. P 谓词寄存器处理尾块；
3. ZA 二维累加状态执行有符号 INT8 外积累加。

没有照搬完整 SME 的可变向量长度、庞大 ZA、FP16/BF16、上下文切换和全部指令编码。比赛 FPGA 的片上存储、布线和 32-bit 外部存储带宽决定了“受 SME 启发的 INT8 子集”比二进制兼容实现更可落地。

## 3. 为什么保留 4×4 原子 MOPA

4×4 是微架构原子瓦片，不是软件矩阵尺寸限制。一次 K=4 的 4×4 INT8 外积需要：

```text
4 destination rows × 4 destination columns × 4 K elements = 64 products
```

64 路版本可在一个 MOPA 算术周期完成 64 个乘积；32/16 路版本分别使用 2/4 个周期。4×4 原子核有以下优点：

- 128-bit Z 正好容纳 16 个 INT8 元素；
- 一个 ZA 仅为 16×32 bit，谓词仅需 16 bit；
- 乘法由移位加法逻辑实现，最终 DSP48=0；
- 低级指令、随机算术回归和尾块处理已经稳定；
- 避免直接构造 8×8 原子核带来的 4 倍累加状态、宽多路器和跨区域布线。

## 4. V2 的 8×8 宏瓦片

V2 没有复制一个新的 8×8 乘法阵列，而是把四个 4×4 ZA 组合为四个象限：

```text
              N 0..3          N 4..7
M 0..3          ZA0              ZA1
M 4..7          ZA2              ZA3
```

每个 K=4 切片依次对四个象限调用同一个 MOPA 核。这样仍保留单一算术实现和低级 ISA 语义，但把描述符调度粒度从 4×4 提升为 8×8：

- A 的 8 行在左右象限间复用；
- B 的 8 列在上下象限间复用；
- 一个宏瓦片完成后按有效行生成 1～8 beat 写 burst；
- 尾行、尾列和尾 K 仍由四组谓词屏蔽。

TinyViT 中宏瓦片计数由 V1 的 2,179 个 4×4 输出瓦片变为 V2 的 546 个 8×8 调度瓦片。两者计数单位不同，但 V2 显著减少了描述符引擎的地址生成、装载和存储控制次数。

## 5. 片上驻留缓存与 burst

`lsme_gemm_v2` 为每个 batch 把 A/B 搬入私有 BRAM，再对所有输出瓦片复用：

| 缓存 | 组织 | 容量 | 映射 |
|---|---:|---:|---:|
| A scratch | 1024×32 | 4 KiB | 1×RAMB36 |
| B scratch | 2048×32 | 8 KiB | 2×RAMB36 |

支持的 V2 上限为 `M≤64、N≤128、K≤64`；正常 B 和 `TRANS_B` 均支持。每行通过 1～8 beat AXI burst 搬运，计算阶段通过真双口 BRAM 分四拍取出 8 行 A 和 8 列 B 所需的 32-bit word。

描述符 word15 的 `V2` 签名选择缓存路径；旧描述符或显式 `STREAM` mode 仍走 V1 4×4 路径，便于兼容和消融对比。

当前版本采用“batch 内全驻留”而不是 ping-pong 双缓冲。这样没有计算/DMA 重叠，`overlap_cycles=0`，但控制更简单、BRAM 规模小，已经达到 1.815×整机加速并保持正时序裕量。双缓冲被保留为后续扩展，而不是本版本必须承担的后端风险。

## 6. 模块堆叠

### CPU 接入层

- `id_stage.v` 识别 `1100` 自定义指令前缀；
- `lacc_core.v` 将寄存器操作数和命令送到外部加速器；
- `lsme_lacc_cdc.v` 用 toggle request/response 协议跨越约 33 MHz CPU 域和 50 MHz 系统域。

### LSME 状态与计算层

- `lsme_core.v`：8×Z、4×P、4×ZA 状态、低级指令及宏瓦片接口；
- `lsme_mopa_core.v`：16/32/64 路有符号 INT8 外积累加；
- `lsme_gemm_v2.v`：缓存 GEMM、8×8 宏瓦片、burst load/store；
- `lsme_bram_tdp.v`：可综合为 RAMB36 的真双口同步存储模板；
- `lsme_softmax_core.v`：最大值归一、base-2 指数近似、Q16 倒数和 Q7 输出；
- `lsme_rmsnorm_core.v`：流式平方和归约、整数平方根、共享精确除法和 INT8 写回；
- `lsme_udiv32.v` / `lsme_isqrt32.v`：面积受控的迭代定点算术单元；
- `lsme_exec_engine.v`：读取 64-byte 描述符并选择 V1/V2、Softmax、VADD 或 RMSNorm；
- `lsme_axi_master.v`：兼容单 word 请求和 1～8 beat burst 的单 outstanding AXI 主机；
- `lsme_csr_axi.v`：MMIO、能力、错误、调度模式和性能计数器。

### SoC 与后端层

- `axi2sram_sp_external.v`：寄存化 SRAM beat 地址、读数据和写脉冲；
- DVI 外设保存图像、热图、分类得分和性能数据，并实时生成 800×600 仪表盘；
- Vivado 实现脚本启用物理优化，检查 DSP=0 和最终 setup slack≥0。

## 7. 软硬件协同优化

### 融合 QKV

启动阶段把三个 `32×32` 权重和 bias 交织为 `32×96`，在计时区内用一次 `64×96×32` GEMM 代替 Q、K、V 三次 GEMM。随后 CPU 只做 head-major 重排。

### 硬件向量加法

position embedding 和两次 residual add 均使用 `VECTOR_ADD` 描述符，支持多行、原位输入输出和 INT8 饱和，减少 CPU 标量循环。

### SME 风格硬件 RMSNorm

gain 向量驻留在 512-bit 本地状态；输入行按 32-bit 流入时同步计算平方和，随后通过共享恢复除法器和两阶段整数平方根得到 RMS。逐元素路径复用同一个除法器，完成 gain 乘法、最近舍入和 INT8 饱和。该结构把三个 RMSNorm、共 192 行从 CPU 迁移到描述符引擎，同时避免组合除法器和大规模并行除法阵列。

## 8. 后端收敛设计

旧外部 SRAM 适配器把 `base + counter/WRAP` 组合地址直接送到板级引脚，最差路径落在接口地址锥。V2 将当前 beat 地址寄存，并只在时序边界更新 `+4` 或 WRAP 地址；读响应在反压时保持，写操作使用寄存化数据与脉冲状态机。

最终物理结果：

- 2026-08-13 正式重跑实现的 WNS `+0.330 ns`，TNS `0`，WHS `+0.022 ns`；
- 0 个未布通或部分布通网络；
- placer/router 均未发现 level>5 的拥塞窗口；
- 最差 setup 路径转移到 Softmax 归一化通路，不再经过 SRAM 引脚；
- A/B scratch 被明确识别为 true dual-port RAM，避免 98,304 bit 被展开为 FF。

## 9. 参数化 HCTA

`soc_top` 参数 `LSME_MOPA_LANES` 支持 16、32、64：

| 路数 | 一个 4×4×4 MOPA 的算术周期 | 特点 |
|---:|---:|---|
| 16 | 4 | 最低 LUT，适合资源受限板卡 |
| 32 | 2 | 吞吐与资源折中 |
| 64 | 1 | XC7A200T 最终发布配置 |

三种配置使用同一 ISA、描述符和软件。模块回归分别通过 202 组随机 MOPA 测试及完整低级指令测试。

## 10. 创新性、可实现性与展示性

创新性体现在：双层指令模型、四 ZA 协同宏瓦片、同一描述符中的 V1/V2 兼容，以及把 SME streaming/reduction 思想扩展到 Transformer Softmax、VADD 和 RMSNorm。

可实现性体现在：12 KiB BRAM 缓存、单一 4×4 算术核复用、共享迭代除法器、有限维度契约、0 DSP、34.61% LUT 和已通过的 50 MHz 物理实现。

技术展示可依次呈现：能力查询、低级 MOPA 自测、V1/V2 消融、TinyViT 逐位结果、DVI 注意力热图、UART 分解计数器，以及 Vivado 的 DSP=0、无拥塞和正 WNS 报告。

## 11. 已知限制

- 仅支持 INT8/S32，不支持 FP16/BF16 和结构化稀疏；
- V2 cache 上限为 M64/N128/K64，超限返回 `0x17`；
- AXI 为单 outstanding，尚未做多请求乱序和 DMA/计算重叠；
- head 重排、merge 和 pooling 仍由 CPU 执行；
- `ACCUMULATE` 与 per-channel shift 标志保留但未实现；
- ZA 未实现操作系统级 lazy context switch。
