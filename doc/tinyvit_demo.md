# TinyViT V2 定点推理与 DVI 演示

## 1. 模型

输入 Fashion-MNIST 28×28 灰度图，运行时在四周补 2 个零像素，得到 32×32：

```text
PatchConv 4×4/4, 1→32
Position embedding, 64×32
RMSNorm
Fused QKV 32→96
4-head attention, each head 64×8
Projection 32→32 + residual
RMSNorm
MLP 32→64→32, ReLU + residual
RMSNorm + token mean
Classifier 32→10
```

训练脚本 `tools/train_tinyvit.py` 直接解析 IDX gzip，并导出自包含 INT8 C header。当前 checkpoint 在完整 10,000 张测试集上的结果：

| 模型 | 准确率 |
|---|---:|
| PyTorch float | 85.64% |
| LSME bit-oriented integer reference | 81.15% |

## 2. 定点格式

激活使用 per-tensor、2 的幂缩放：

| 数据 | Fraction bits |
|---|---:|
| 输入像素 | 7 |
| token / q / k / v / context / final | 5 |
| MLP hidden | 4 |
| RMSNorm gain | 6 |

权重根据张量最大绝对值自动选择 fraction bits，bias 使用 `input_fraction + weight_fraction` 的 S32 格式。硬件只执行整数累加和常数右移，不需要运行时浮点 scale。

关键舍入规则：

- GEMM 重量化：符号/幅值对称 round-to-nearest，再做 INT8 saturation；
- RMSNorm：整数 mean-square、floor integer sqrt、Q15 reciprocal 和逐元素精确余数修正；
- token mean：round-to-nearest-even，与 NumPy `rint` 一致；
- Softmax：base-2 ROM + Q16 reciprocal，输出 Q7 byte。

`tools/evaluate_quantized_tinyvit.py` 是软件位精确参考；十个演示样例保存 10 个期望 logits，板上运行会逐项比较。

## 3. 15 个描述符的执行序列

| # | 算子 | M×N×K / batch | 路径与输出 |
|---:|---|---|---|
| 1 | Patch GEMM | 64×32×16 | V2，INT8 + bias |
| 2 | Position VADD | 64×32 | 原位 INT8 saturation |
| 3 | RMSNorm 1 | 64×32 | 流式归约、INT8 gain |
| 4 | Fused QKV | 64×96×32 | V2，INT8 + bias |
| 5 | QKᵀ | 64×64×8 / 4 | V2，S32，`TRANS_B+HEAD4` |
| 6 | Softmax | 64×64 / 4 | Q7 byte |
| 7 | Attention×V | 64×8×64 / 4 | V2，INT8，`HEAD4` |
| 8 | Projection | 64×32×32 | V2，INT8 + bias |
| 9 | Residual 1 VADD | 64×32 | 原位 INT8 saturation |
| 10 | RMSNorm 2 | 64×32 | 流式归约、INT8 gain |
| 11 | MLP1 | 64×64×32 | V2，INT8 + bias + ReLU |
| 12 | MLP2 | 64×32×64 | V2，INT8 + bias |
| 13 | Residual 2 VADD | 64×32 | 原位 INT8 saturation |
| 14 | RMSNorm 3 | 64×32 | 流式归约、INT8 gain |
| 15 | Classifier | 4×12×32 | V2，S32 + bias |

Q/K/V 原来是三次 `64×32×32` GEMM。V2 在计时区之前把权重交织成 `32×96`，在计时区内只提交一次 `64×96×32` GEMM；输出再由 CPU 重排成 4 个 head。

CPU 仍执行：图像补零/patch 展开、QKV head-major 重排、head merge、池化、热图和类别条归一化。Position add、两次 residual 和三个 RMSNorm 均已迁移到硬件。

分类器将 pooled token 放在 4×32 输入的第一行，其余三行清零；输出补齐到 12 类，软件只使用前 10 个 logits。

## 4. V2 性能计数

完整 SoC XSim 样例 0：

| 指标 | 数值 |
|---|---:|
| CPU inference cycles | 684,692（完整固件 SoC 回归） |
| Descriptor engine cycles | 614,126 |
| Compute cycles | 358,048 |
| Memory-stall cycles | 95,284 |
| Compute/DMA overlap cycles | 0 |
| AXI read beats | 32,276 |
| AXI write beats | 28,208 |
| MOPA count | 12,864 |
| 8×8 macro tiles | 546 |
| Softmax rows | 256 |
| RMSNorm rows | 192 |
| Last classifier descriptor | 937 cycles |

`overlap=0` 是当前“全驻留后计算”策略的预期结果，不是计数器失效。它明确指出下一阶段的性能空间是 ping-pong DMA/compute overlap；本版本优先选择更容易验证和收敛的 resident-cache 结构。

## 5. 演示样例

导出器从每一类前 256 个测试样本中选择一个整数预测正确、top-1 margin 最大的样本：

```text
class: 0    1    2   3   4    5    6   7    8   9
index: 1403 1117 723 466 109 1067 1728 225 1344 940
```

这些样例不参与训练，仅用于稳定现场演示。

## 6. DVI XAI 仪表盘

DVI 分辨率为 800×600，包含：

- `INPUT`：28×28 原图，8 倍像素缩放；
- `ATTENTION`：4 heads × 64 queries 的累计注意力，归一化为 8×8 热图；
- `CLASS SCORE`：10 个 logits 的 min-max 归一化条形图；
- `CYCLES/MOPA/TILES/DESC/LANES/ACC`：实时性能与模型信息；
- 顶部 `MOPA → SOFT → VADD → RMS` 数据流铭牌及 `SME INT8` 标识：把
  低级外积、整数 Softmax、饱和残差与流式 RMSNorm 的硬件功能直观地关联起来；
- `PRED/EXP` 和绿色/红色状态灯。
- 底部 `IP PASS/IP FAIL` 状态带：复用逐位校验和分类匹配的真实状态位，不依赖
  预制动画或额外软件标记。

UART 还会输出 engine、compute、stall、overlap、AXI read/write beat 与 last descriptor cycles，适合现场解释瓶颈。

CPU 通过 `0xbf10_0000` DVI MMIO 发布一帧：

| Offset | 内容 |
|---:|---|
| 0x010 | enable、predicted、expected、sample、lanes、status |
| 0x014 | cycles |
| 0x018 | MOPA count |
| 0x01c | tile count |
| 0x020 | descriptor count |
| 0x024 | float accuracy ×10000 |
| 0x028 | Fashion-MNIST test index |
| 0x100～0x40c | 784 image bytes |
| 0x500～0x53c | 64 heatmap bytes |
| 0x600～0x608 | 10 class-score bytes |

驱动先清 enable，写完三个数据区和指标后再置 enable，显示器不会看到半帧更新。

## 7. 板级运行

1. 使用 `fpga/project/Loongson_Soc.runs/impl_1/soc_top.bit` 配置 FPGA；
2. 将同一最终 RTL/ABI 版本配套的 `sdk/user-sample.bin` 写入 BaseRAM。网页
   上传器若要求“偏移”，填写 `0x00000000`；`0x1c00_0000` 是 CPU 的链接地址，
   不是网页上传偏移；
3. 连接 800×600 DVI 显示器和 115200 UART；
4. 解除复位并等待 `TINYVIT_DEMO_PASS`；
5. 改变拨码开关低 4 位选择样例 0～9；置 `SW[15]=1` 后，可每 1.8 秒自动
   轮播一个真实样例，便于远程录制时连续展示 DVI 刷新效果。

只替换 bitstream 或软件镜像中的一个可能导致自定义指令、描述符 ABI 或能力版本不匹配。

## 8. 参考运行输出

```text
TINYVIT_BOOT_LSME_V2_RMSNORM
LSME_DEMO_CUSTOM_QUERY raw=0x024040bf
LSME_DEMO_CSR_CAPABILITY raw=0x024040bf match=yes
LSME_DEMO_ARCH version=2 lanes=64 max_cached_k=64 features=0xbf
LSME_DEMO_CONTROL manual=SW[3:0] automatic_carousel=SW[15]
LSME_DEMO_STAGE=1 INPUT sample=0
LSME_DEMO_STAGE=2 EXEC descriptors=15 path=V2_cached+HW_RMSNorm
expected=0 (T-shirt/top), predicted=0 (T-shirt/top), bit_exact=yes
logits: 62495 12017 -1841 6929 -37231 -7190 17176 -18930 -4761 -23736
lanes=64 cycles=684692 descriptors=15 mopa=12864 tiles=546 softmax_rows=256 rmsnorm_rows=192
engine=614126 compute=358048 stall=95284 overlap=0 axi_read=32276 axi_write=28208 last_desc=937
LSME_DEMO_COMPARE v1_cycles=1827549 current_cycles=684692 speedup=2.669x reduction=62.53%
LSME_DEMO_VERIFY logits=10/10 bit_exact=yes classification=yes
TINYVIT_DEMO_PASS
```

此处 `current_cycles` 是**演示固件的现场观测字段**，会随 UART banner、能力字回读、
仿真日志和编译布局产生几十个 cycle 的微小变化；近期完整 SoC 仿真曾观察到
`684,658`、`684,680` 和 `684,692`。正式提交包采用随附完整固件回归日志中的
`684,692`，精简远程固件采用随附日志中的 `684,654`。这些细小差异不改变 LSME
描述符执行、logits 或约 2.669× 加速结论。视频中引用数字时，应明确为“完整 SoC
仿真结果”；远程板现场视频只用来证明固件、DVI 和交互真实运行。
