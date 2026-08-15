# 决赛自主 IP 初步优化：SME 风格流式 RMSNorm

## 1. 优化目标

决赛要求重点说明自主 IP 的设计、验证和 PPA。上一版 LSME 已完成 cached GEMM、Softmax 与 VADD，但整机仍有三个 CPU RMSNorm 热点。本次没有继续扩大乘法阵列，而是新增 Transformer 专用的流式归约模块，使自主 IP 从“矩阵乘加速器”扩展为覆盖线性算子、归约算子、非线性算子和残差算子的 AI 执行子系统。

## 2. 与 Arm SME 思想的对应

本设计不是复制 Arm 指令编码，而是借鉴其微架构思想：

- streaming mode：输入行按 32 位字连续流入，装载同时计算平方和；
- reduction state：一行的平方和、均方值和 RMS 作为跨拍状态保存；
- locally resident vector：gain 向量只装载一次，驻留在 512 位本地状态中；
- predicated tail：最后不足 4 个 INT8 元素时按 byte strobe 写回；
- shared arithmetic pipeline：均值除法和逐元素归一化共用一个 32 拍迭代除法器。

对应的新描述符操作为 `LSME_OP_RMSNORM=4`，软件仍通过已有 `EXEC/WAIT` 自定义指令提交，因而不增加 CPU 流水线中的 outstanding 指令复杂度。

## 3. RTL 数据流

```text
gain AXI load ──> 512-bit resident gain
                         │
input row stream ──> INT8 square reduction ──> sum/N
                                              │
                                      iterative isqrt
                                              │
input × gain ──> shared exact divider ──> round/saturate ──> packed writeback
```

主要文件：

- `rtl/ip/lsme/lsme_rmsnorm_core.v`：行缓冲、流式归约、量化和访存状态机；
- `rtl/ip/lsme/lsme_udiv32.v`：32 位恢复除法器，均值与元素除法复用；
- `rtl/ip/lsme/lsme_isqrt32.v`：两阶段 floor integer sqrt；
- `rtl/ip/lsme/lsme_exec_engine.v`：operation=4 解码、访存复用和性能计数；
- `sdk/software/examples/tinyvit_demo/tinyvit_runtime.c`：三个 RMSNorm 描述符调用。

为了降低后端违例风险，设计没有实例化组合除法器，也没有复制 32 路除法单元。小位宽乘法显式使用 LUT，最终仍为 DSP48=0；新增模块不使用 BRAM，避免打乱原有 A/B scratch 的放置。

## 4. 功能与验证

RMSNorm 完整支持：

- `rows × columns × batch`，`columns≤64`；
- 独立 row/batch stride；
- INT8 输入、INT8 gain、INT8 输出；
- floor integer sqrt、nearest rounding、signed saturation；
- 非 4 对齐尾块和原有 AXI 错误传播。

验证覆盖三层：

1. `lsme_rmsnorm_tb`：正负 gain、两个 batch、非 4 对齐列数、小均方值、舍入及饱和；
2. `lsme_exec_engine_tb`：描述符解码、DMW 地址转换、共享访存和 RMSNorm 行计数；
3. 完整 SoC XSim：真实 LoongArch 指令执行三个 RMSNorm，10 个 logits 逐位一致并输出 `TINYVIT_DEMO_PASS`。

修复过程中还发现并闭环了整数平方根的阶段划分问题：规格化阶段与正式求根阶段原先混合，小均方值 19 会错误得到 8；分离两阶段后得到正确结果 4，并加入永久回归用例。

## 5. 性能结果

同一模型、样例、CPU 频率及 bit-exact 判据：

| 指标 | V1 stream | cached V2 | V2 + HW RMSNorm |
|---|---:|---:|---:|
| CPU cycles | 1,827,549 | 1,007,062 | **684,692** |
| 相对 V1 | 1.000× | 1.815× | **2.669×** |
| 描述符数 | 11 | 12 | **15** |
| Softmax / RMSNorm rows | 256 / 0 | 256 / 0 | **256 / 192** |
| AXI read / write beats | — | 30,668 / 26,672 | **32,276 / 28,208** |
| bit exact | yes | yes | **yes** |

硬件 RMSNorm 相对上一版 V2 减少 322,370 cycles，即周期下降 32.01%、性能提升 1.4708×。整机 engine cycles 上升是预期现象，因为原先由 CPU 执行的工作被纳入了可观测的描述符引擎；总 CPU cycles 明显下降才是系统级收益。

## 6. PPA 与后端结果

器件 `xc7a200tfbg676-1`，Vivado 2025.2，系统时钟 50 MHz：

| 指标 | cached V2 | V2 + HW RMSNorm | 增量 |
|---|---:|---:|---:|
| SoC LUT | 45,539 | **46,924** | +1,385（+3.04%，含 DVI 演示铭牌） |
| SoC FF | 19,900 | **21,803** | +1,903（+9.56%，含 DVI 演示状态带） |
| BRAM36 / BRAM18 | 3 / 21 | **3 / 21** | 0 |
| DSP48 | 0 | **0** | 0 |
| WNS / WHS | +0.318 / +0.036 ns | **+0.330 / +0.022 ns** | 均满足约束 |

层次化报告中 `u_rmsnorm` 为 2,732 LUT、1,771 FF，其中共享除法器 272 LUT/135 FF，平方根单元 237 LUT/99 FF。全设计无 setup/hold 失败端点、无 level>5 拥塞窗口。

## 7. 决赛展示建议

一分钟自主 IP 视频可依次显示：

1. 架构图高亮 `stream → reduction → isqrt/divide → writeback`；
2. UART 显示 `descriptors=15`、`RMSNorm rows=192`；
3. 同屏对比 `1,007,062 → 684,692 cycles`；
4. 展示 10 个 logits 逐位一致与 `TINYVIT_DEMO_PASS`；
5. 展示 Vivado `u_rmsnorm` 层次资源、DSP=0、WNS=+0.330 ns；DVI 演示铭牌
   只增加少量 LUT/FF，未改变 BRAM/DSP 数量。

答辩时应强调：创新点不是“再加一个固定算子”，而是把 SME 的流式状态和归约思想映射到 LoongArch 描述符体系，并通过共享迭代算术单元控制面积与后端风险。
