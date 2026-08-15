# V2 验证、综合与发布记录

## 1. 验证策略

验证从算术单元逐层扩展到完整 SoC：

```text
MOPA arithmetic
  → Z/P/ZA low-level core
  → Softmax / AXI single+burst master
  → V2 cached GEMM / true-dual-port BRAM
  → streaming RMSNorm / descriptor engine / in-place VADD
  → LSME top MMIO + LACC
  → asynchronous CPU/system CDC
  → registered external SRAM adapter
  → LoongArch CPU + SRAM + UART full-SoC TinyViT
  → routed implementation + bitstream
```

最终判据不是只检查 top-1。模型导出器保存每个演示样例的 10 个期望 S32 logits，裸机程序逐项比较，全部一致才输出 `bit_exact=yes`。

## 2. RTL 回归

`make rtl-test` 的最终结果：

| 测试 | 覆盖 | 结果 |
|---|---|---|
| `lsme_mopa_tb` | 随机有符号 INT8、谓词、初始 ZA | 16/32/64 路各 202 组通过 |
| `lsme_core_tb` | CTRL、LDZ/transpose、PSET、bias、ZERO、SMOPA、STZA | 三种路数通过 |
| `lsme_softmax_tb` | count 1/64/0、极值、100 组随机 | 104 组通过 |
| `lsme_rmsnorm_tb` | 非对齐尾块、正负 gain、batch、小均方值、舍入饱和 | 4 行逐元素通过 |
| `lsme_axi_master_tb` | single read/error、AW/W 顺序、1～8 beat 接口 | 4 场景通过 |
| `lsme_gemm_v2_tb` | normal/transposed、S32/INT8、尾块、batch、融合 QKV | 5 组通过，QKV case 24,864 cycles |
| `lsme_exec_engine_tb` | V2 GEMM、Softmax、VADD、RMSNorm 与计数器 | 5 描述符通过 |
| `lsme_top_tb` | MMIO、LACC、AXI burst、V2 feature/counters | 3 描述符通过 |
| `lsme_lacc_cdc_tb` | 异步时钟、随机命令/延迟 | 22 组通过 |
| `axi2sram_sp_external_tb` | 4-beat SRAM burst read/write | 通过 |

终端标志为：

```text
LSME_RTL_REGRESSION_PASS
```

## 3. 软件与模型验证

| 项目 | 结果 |
|---|---:|
| Float Fashion-MNIST | 8564/10000 = 85.64% |
| Integer reference | 8115/10000 = 81.15% |
| 裸机 ELF text/data/bss | 42,452 / 23,708 / 185,356 bytes |
| 总静态占用 | 251,516 bytes |
| SRAM binary | 67,500 bytes |

RMSNorm reciprocal 优化另做了穷举一致性检查：RMS=1～127，输入和 gain 均遍历 -128～127，结果与原逐元素整数除法完全一致。

## 4. 完整 SoC 行为仿真

仿真包含真实 LoongArch32R 指令执行、CPU/系统异步时钟、AXI crossbar、外部 SRAM 模型、LACC CDC、LSME 和 UART，不是直接调用加速器 testbench。

最终输出（本次正式完整固件回归）：

```text
expected=0 (T-shirt/top), predicted=0 (T-shirt/top), bit_exact=yes
logits: 62495 12017 -1841 6929 -37231 -7190 17176 -18930 -4761 -23736
lanes=64 cycles=684692 descriptors=15 mopa=12864 tiles=546 softmax_rows=256 rmsnorm_rows=192
engine=614126 compute=358048 stall=95284 overlap=0 axi_read=32276 axi_write=28208 last_desc=937
TINYVIT_DEMO_PASS
```

远程精简固件保留相同推理路径，但压缩了 UART 文案；随正式包发布的 SoC 日志为
684,654 cycles。完整与精简镜像均有独立 MIF、ELF 和 SHA-256，不得交叉混用。

相同模型、样例和 CPU 频率下，V1 为 1,827,549 cycles；cached V2 为 1,007,062 cycles；加入硬件 RMSNorm 后本次完整回归为 684,692 cycles。相对 cached V2 再提升 1.4708×，相对 V1 总加速 2.669×。

## 5. Vivado 物理实现

工具：Vivado 2025.2；器件：`xc7a200tfbg676-1`。

### 最终资源

| 资源 | Used | Available | Utilization |
|---|---:|---:|---:|
| Slice LUT | 46,924 | 133,800 | 35.07% |
| Logic LUT | 45,527 | 133,800 | 34.03% |
| LUTRAM | 1,397 | 46,200 | 3.02% |
| Slice Register | 21,803 | 267,600 | 8.15% |
| RAMB36 | 3 | 365 | 0.82% |
| RAMB18 | 21 | 730 | 2.88% |
| Block RAM Tile | 13.5 | 365 | 3.70% |
| DSP48E1 | 0 | 740 | 0.00% |

层次化占用：

| 模块 | LUT | FF | RAMB36 | RAMB18 |
|---|---:|---:|---:|---:|
| `u_lsme` | 32,839 | 13,910 | 3 | 1 |
| `u_lsme/u_exec/u_rmsnorm` | 2,732 | 1,771 | 0 | 0 |
| `u_lsme/u_exec/u_gemm_v2` | 4,731 | 1,504 | 3 | 0 |
| `u_lsme/u_core` | 17,500 | 4,525 | 0 | 0 |
| `u_cpu` | 8,574 | 5,591 | 0 | 20 |
| `u_axi_dvi` | 3,404 | 435 | 0 | 0 |

综合日志明确记录：

```text
The signal ".../memory_reg" was recognized as a true dual port RAM template.
```

A scratch 映射为 1×RAMB36，B scratch 映射为 2×RAMB36。早期版本因把两个写端口放在同一时序进程而被展开为 98,304 个 FF，导致约 134k LUT 和布局失败；拆分为 Vivado 真双口模板后恢复到上述资源并完成布局。

### 时序与布线

| 指标 | 结果 |
|---|---:|
| `sys_clk` | 50.000 MHz |
| 全设计 WNS / TNS | +0.330 ns / 0.000 ns |
| 全设计 WHS / THS | +0.022 ns / 0.000 ns |
| CPU clock WNS | +0.865 ns |
| Setup failing endpoints | 0 / 72,617 |
| Hold failing endpoints | 0 / 72,617 |
| Unrouted / partially routed nets | 0 / 0 |
| Level>5 congestion windows | 0 |

Vivado 结论：`All user specified timing constraints are met.`

最差 setup 路径仍位于 `lsme_softmax_core` 的归一化输出链，正式重跑后 slack 为 +0.330 ns。旧版本的外部 SRAM `base+counter/WRAP` 地址锥不再出现在关键路径，证明寄存化 SRAM adapter 降低了接口后端风险。

独立 `report_drc` 记录了 RAM async-control 类 warning，但无 error；`write_bitstream` 的前置 DRC 同样为 0 error，Bitgen 成功。实现脚本不添加伪造 false path、multicycle 或手工 pblock。

## 6. V1/V2 公平对比

| 指标 | V1 stream | V2 cached | 变化 |
|---|---:|---:|---:|
| CPU inference cycles | 1,827,549 | 1,007,062 | -44.90% |
| Speedup | 1.000× | 1.815× | +81.47% |
| MOPA | 12,824 | 12,864 | +0.31% |
| LUT | 36,692 | 45,539 | +24.11% |
| FF | 18,010 | 19,900 | +10.49% |
| BRAM tiles | 10.5 | 13.5 | +3.0 |
| DSP | 0 | 0 | 不变 |
| WNS | +0.134 ns | +0.318 ns | +0.184 ns |

MOPA 略增来自 8×8 宏瓦片的边界象限填充；整机仍因操作数复用、burst、QKV 融合和 VADD 硬件化大幅加速。

## 7. 构建与报告

```bash
make final-regression
make impl
make bitstream
make final-submission
```

`run_impl.tcl` 每次重置 `synth_1`，启用 timing-oriented strategy、physical optimization 和 route explore，并执行：

- routed utilization 与 hierarchical utilization；
- timing summary 和 20 条 critical paths；
- congestion 与 DRC；
- DSP48E1 数量必须为 0；
- worst setup slack 必须非负。

## 8. 发布产物

- `release/final_submission_v2_rmsnorm_20260813/lsme_v2_rmsnorm_final.bit`
- `release/final_submission_v2_rmsnorm_20260813/lsme_v2_rmsnorm_preflight.bin`
- `release/final_submission_v2_rmsnorm_20260813/tinyvit_v2_rmsnorm_final_remote.bin`
- 同目录的完整排障固件、三份 MIF、PPA 报告、RTL/SoC 日志和 `SHA256SUMS`

远程平台必须先运行预检，再使用同目录的 bitstream 与远程演示镜像；不得与历史
V1、stream-safe 或 v2-compat 文件混合。
