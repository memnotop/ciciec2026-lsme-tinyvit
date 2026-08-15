# LSME V1/V2/RMSNorm 性能与方案对比

## 1. 对比原则

定量对比使用同一 TinyViT 模型、同一样例 0、相同 LoongArch CPU/系统时钟、相同 64-lane MOPA、相同量化参数和相同 `bit_exact` 判据。V2 的 10 个 logits 与 V1/Python 参考逐位一致，因此加速不是通过降低精度或改变模型获得。

## 2. 实测结果

| 指标 | V1：4×4 stream | V2：cached macro8 | 变化 |
|---|---:|---:|---:|
| CPU inference cycles | 1,827,549 | 1,007,062 | -820,487（-44.90%） |
| 相对性能 | 1.000× | 1.814733× | +81.47% |
| 描述符 | 11 | 12 | +1，新增 3 个 VADD、QKV 由 3 合 1 |
| MOPA count | 12,824 | 12,864 | +0.31% |
| 调度瓦片 | 2,179 个 4×4 | 546 个 8×8 | 单位不同 |
| LUT | 36,692 | 45,539 | +8,847（+24.11%） |
| FF | 18,010 | 19,900 | +1,890（+10.49%） |
| BRAM tiles | 10.5 | 13.5 | +3.0 |
| DSP48 | 0 | 0 | 不变 |
| WNS | +0.134 ns | +0.318 ns | +0.184 ns |

新增硬件 RMSNorm 后，本次完整固件 SoC 回归周期由 1,007,062 降到 **684,692**，下降 32.01%，性能提升 1.4708×；相对 V1 总加速为 2.669×。2026-08-13 正式重新布线版本为 46,924 LUT、21,803 FF、DSP=0、WNS +0.330 ns、WHS +0.022 ns，BRAM 数量不变。录制用精简固件因启动/DVI 发布文案不同，SoC 仿真为 684,654 cycles；两者都以随包日志为准。

性能/资源折中可概括为：使用 24.11% LUT、10.49% FF 和 3 个 BRAM tile 增量，换取 44.90% 整机周期下降；DSP 仍为 0，器件 LUT 利用率仍仅 33.83%。

## 3. 加速来源

### A/B 驻留复用

V1 每个 4×4 输出瓦片都从外部 SRAM 重复读取 A/B。V2 每个 batch 只把 A/B 搬入 4 KiB/8 KiB BRAM 一次，随后所有 M/N 瓦片从片上读取。对 TinyViT 的 M/N 复用维度尤其有效。

### 8×8 宏瓦片

四个 ZA 分别保存 8×8 输出的四个象限。A top/bottom 和 B left/right 在四次 4×4 MOPA 间协同复用，减少地址生成、加载和 store 控制次数，同时保留单一 MOPA 算术核。

### AXI burst

V1 以单 word 请求为主；V2 的缓存装载和结果写回使用 1～8 beat INCR burst。外部 SRAM adapter 可连续返回 read beat，并在 backpressure 时保持数据。

### QKV 融合

三次 `64×32×32` GEMM 合并为一次 `64×96×32` GEMM，减少描述符固定开销和 A 矩阵重复装载。

### VADD 与 RMSNorm

Position/residual 的三个 CPU 标量循环迁移到硬件 VADD。决赛优化进一步加入流式 RMSNorm：装载输入时完成平方和归约，使用共享迭代除法器和整数平方根，三个算子共 192 行全部进入描述符引擎并保持位精确。

## 4. 性能计数器解释

| V2 计数器 | 样例 0 | 解释 |
|---|---:|---|
| Engine cycles | 356,850 | 所有 12 个描述符的执行引擎活动周期 |
| Compute cycles | 133,024 | V2 宏瓦片读取/MOPA 活动周期 |
| Memory stall cycles | 82,924 | V2 load/store 等待周期 |
| Overlap cycles | 0 | 当前无 ping-pong overlap |
| AXI read beats | 30,668 | 描述符、操作数及其他硬件读取 |
| AXI write beats | 26,672 | GEMM、Softmax、VADD 输出写入 |

整机 CPU cycles 不等于 engine cycles，因为 CPU 还执行 patch 展开、RMSNorm、head 重排、pooling 和 DVI 数据准备。V2 后仍有约 65% 整机时间位于非描述符区间，这为后续 RMSNorm/重排硬件化提供了清晰方向。

## 5. 与其他成熟路线的技术对比

| 方案 | 优点 | 在本 FPGA/比赛中的代价 | LSME V2 选择 |
|---|---|---|---|
| 完整 Arm SME 风格大 ZA | 指令丰富、向量长度可扩展、矩阵状态强 | ZA/rename/context 状态大，布线和验证复杂，超出教学 SoC 接口范围 | 保留 Z/P/ZA 与外积思想，裁剪为 INT8 4×4 原子 + 8×8 宏瓦片 |
| 大型 systolic array | 连续大 GEMM 吞吐高、数据复用规则 | 常依赖大量 DSP/BRAM；小矩阵、Softmax、尾块和 ISA 展示较弱 | 用描述符和谓词支持多尺寸，DSP=0，并覆盖 Softmax/VADD |
| 固定函数 HLS GEMM IP | 开发快、单算子容易达到高频 | 创新性与体系结构可见性不足，难展示 Z/P/ZA 和自定义指令 | 低级指令与高级描述符共享同一 MOPA 状态和算术核 |
| V1 4×4 streaming | 控制简单、资源最低 | 外部带宽重复、地址控制次数多，TinyViT 周期高 | 保留为兼容/消融路径，默认使用 V2 cached |
| V2 resident cache | 资源可控、复用充分、易验证 | 受 M64/N128/K64 容量限制，无 DMA/计算重叠 | 当前比赛发布方案 |

## 6. 后端改进证据

V1 的最差路径位于外部 SRAM 的组合地址生成。V2 把 beat 地址、写数据和读响应寄存化后：

- 最差路径转移到 Softmax 内部，而不是 SRAM I/O；
- WNS 从 +0.134 ns 提升到 +0.318 ns；
- TNS/THS 均为 0；
- 0 个未布通网络；
- 无 level>5 拥塞窗口；
- 不依赖 false path、multicycle 或 pblock 掩盖问题。

曾出现的一次布局失败也形成了可展示的工程闭环：错误 BRAM 模板将 98,304 bit 缓存展开为 FF，导致约 134k LUT；根据综合日志拆分真双口 RAM 的两个写进程后，缓存映射为 3×RAMB36，最终 LUT 降至 45,539 并完成 bitstream。

## 7. 后续优化优先级

1. 将 Softmax 输出归一化拆成两级流水，进一步提高 WNS；
2. 对 A/B 缓存增加 ping-pong bank，使 load/store 与 macro compute 重叠；
3. 增加 transpose/repack 描述符，降低剩余 CPU 数据重排周期；
4. 在不改变 ISA 的前提下探索 32/64-lane 动态功耗配置；
5. 若器件允许 DSP，可增加可选 DSP MOPA backend，与当前 DSP-free backend 做编译时对比。
