# LSME 整数块驻留融合注意力设计

## 1. 设计结论

新增一个高级描述符操作：

```text
LSME_OP_FUSED_ATTENTION = 5
```

它在一个描述符中完成：

```text
QKᵀ → 片上 Score tile → 原整数 Softmax → Probability×V → Context
```

Score 和 Probability 不写入外部 SRAM。最终只写：

- token-major INT8 Context；
- 可选的 64 项 attention column-sum，用于恢复当前 DVI 热图。

第一版明确不实现 Online Softmax。原因是当前模型以 10 个 S32 logits 逐位一致为最终判据，而 Online Softmax 会改变定点重标定和舍入顺序。第一版复用现有 `lsme_softmax_core`，先完成可证明 bit-exact 的 IO-aware 融合；后续才研究 Online Softmax。

## 2. 学术定位

本设计借鉴 FlashAttention 的 IO-aware 分块思想，以及 Arm SME 的流式执行、ZA 二维状态和外积累加思想，但不复制其指令编码：

- FlashAttention 依据：中间注意力矩阵驻留片上，减少高层存储器往返；
- SME 依据：QK 和 AV 都复用现有 8×8 macro/4×4 MOPA 与四块 ZA；
- 全整数依据：沿用现有整数 Softmax、Q7 Probability 和 INT8 requantization；
- LoongArch 扩展：通过 LACC `EXEC/WAIT` 提交一个 64-byte 融合描述符。

参考论文：

- Tri Dao et al., *FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness*, NeurIPS 2022：<https://arxiv.org/abs/2205.14135>
- Maxim Milakov and Natalia Gimelshein, *Online Normalizer Calculation for Softmax*, 2018：<https://arxiv.org/abs/1805.02867>
- Sehoon Kim et al., *I-BERT: Integer-only BERT Quantization*, ICML 2021：<https://arxiv.org/abs/2101.01321>

本项目的自主创新点是：在无 DSP 的 LoongArch/Artix-7 系统中，将 MOPA、位精确整数 Softmax、片上 tile 和注意力可解释性统计组合为同一条体系结构数据流。

## 3. 第一版支持范围

为了控制 RTL、验证和后端风险，第一版支持当前 TinyViT 所需且参数化程度足够展示的范围：

| 参数 | 范围 |
|---|---:|
| Query 数 M | 1～64 |
| Key 数 N | 1～64 |
| Head dimension K | 固定 8 |
| Head/batch 数 | 1～4 |
| Query tile | 8 行 |
| Key tile | 8 列 |
| 数据 | Q/K/V INT8，Score/ZA S32，Probability UQ7，Context INT8 |

地址必须 4-byte 对齐。Q/K/V 采用 `[head][token][lane]`，每行 8 byte；输出直接采用 `[query][head][lane]`，不再由 CPU 执行 `merge_heads()`。

## 4. 描述符 ABI

| Word | 原字段 | Fused Attention 含义 |
|---:|---|---|
| 0 | `op_flags` | op=5；`TRANS_B + OUTPUT_INT8 + HEAD4` |
| 1 | `src0` | Q 地址 |
| 2 | `src1` | K 地址 |
| 3 | `dst` | token-major Context 地址 |
| 4 | `bias` | V 地址；本操作中不表示 bias |
| 5 | `m_n` | low16=query count，high16=key count |
| 6 | `k_batch` | low16=head dimension=8，high16=head count |
| 7 | `src0_row_stride` | Q token stride，当前为 8 |
| 8 | `src1_row_stride` | K/V token stride，当前为 8 |
| 9 | `dst_row_stride` | Context query stride，当前为 32 |
| 10 | `src0_batch_stride` | Q head stride，当前为 512 |
| 11 | `src1_batch_stride` | K/V head stride，当前为 512 |
| 12 | `dst_batch_stride` | Context head offset，当前为 8 |
| 13 | `quant_head` | `{head_dim, head_count, score_shift, context_shift}` |
| 14 | `user_tag` | 推荐 `0x46415454`，ASCII `FATT` |
| 15 | `aux0` | 64×U32 attention column-sum 输出地址；0 表示关闭 |

地址公式：

```text
Q[h,q,d] = src0 + h*word10 + q*word7 + d
K[h,k,d] = src1 + h*word11 + k*word8 + d
V[h,k,d] = word4 + h*word11 + k*word8 + d

Context[q,h,d] = dst + q*word9 + h*word12 + d
```

该布局使下一层 Projection 可以直接读取 Context，删除 `context_head_store` 和 CPU `merge_heads()`。

## 5. 位精确数学语义

### 5.1 QKᵀ

```text
score[h,q,key] = Σ(d=0..7) signed(Q[h,q,d]) * signed(K[h,key,d])
```

Score 保持完整 S32，计算顺序与当前 `TRANS_B` GEMM 相同。

### 5.2 Softmax

每个 query 行把 64 个 S32 Score 按原有位序送入 `lsme_softmax_core`：

```text
delta = clamp((row_max - score) >> score_shift, 0, 255)
```

随后严格复用现有：

- base-2 exponent ROM；
- Q16 reciprocal LUT；
- positive half-up normalization；
- `[0,127]` UQ7 输出。

不允许修改 ROM、reciprocal、扫描顺序或行内舍入位置。

### 5.3 AV

```text
acc[h,q,d] = Σ(key=0..N-1) probability[h,q,key] * signed(V[h,key,d])
```

Probability 范围为 0～127，因此通过有符号 INT8 MOPA 输入时数值不变。

### 5.4 Context requantization

逐字复制 `lsme_gemm_v2.requant_s8()`：

```text
magnitude = abs(acc)
rounded   = (magnitude + 2^(context_shift-1)) >> context_shift
signed    = acc < 0 ? -rounded : rounded
context   = clamp(signed, -128, 127)
```

TinyViT 使用 `context_shift=7`。

## 6. 片上存储组织

每次只处理一个 head，K/V 在该 head 内驻留，Q 按 8 行 tile 搬入。

| Memory | 组织 | 容量 | 生命周期 |
|---|---:|---:|---|
| Score scratch | 512×32 | 16 Kibit | 一个 8×64 Score tile |
| K/V scratch | 256×32 | 8 Kibit | K 占 0～127，V 占 128～255；一个 head |
| Q/Probability scratch | 128×32 | 4 Kibit | 先放 8×8 Q，QK 完成后覆盖为 8×64 Probability |
| Attention sum | 64×16 | 1 Kibit | 整个描述符，最后零扩展写 U32 |

预计综合为 3×RAMB18；Attention sum 可以使用 FF 或 LUTRAM。项目当前仅使用 21/730 个 RAMB18，因此容量风险很低。

Q/Probability 复用的关键顺序是：

```text
载入一个 Q tile
 → 完成该 tile 对全部 K 的 QK
 → Q 不再需要
 → 同一 memory 覆盖写 Probability
 → 完成 AV
 → 载入下一个 Q tile
```

## 7. 共享 MOPA 接口

不修改 `lsme_gemm_v2` 内部。新增：

```text
rtl/ip/lsme/lsme_fused_attention.v
```

该模块与 `lsme_gemm_v2` 并列，通过 `lsme_exec_engine` 对以下接口进行静态 owner 仲裁：

- burst AXI command/read/write；
- 8×8 macro operand、predicate、ZA init；
- macro ready/done/ZA output。

owner 只由执行状态决定：

```text
ST_G_V2_WAIT  → GEMM V2 owner
ST_FA_WAIT    → Fused Attention owner
```

只有当前 owner 能看到 `burst_cmd_ready`、`burst_done`、`macro_ready` 和 `macro_done`，避免非 owner 状态机误推进。

QK 和 AV 都复制 `lsme_gemm_v2` 已验证的四阶段 operand pack：

```text
READ_ISSUE → READ_CAPTURE，read_phase=0..3
```

QK：

- A = 8 个 query 行；
- B = 8 个 key 行，按 TRANS_B 方式装入；
- K=8，执行两个 K=4 macro slice；
- macro_first 仅在第一个 K slice 置位。

AV：

- A = 8 行 Probability，每次读取连续 4 个 key；
- B = V 的 4 个 key 行×8 个 lane，按普通 B 方式装入；
- K=N，按 4 递增；
- ZA 最终保存 8×8 Context accumulator。

## 8. 控制状态机

状态机分为七段。

### A. 配置与 head 装载

```text
IDLE
VALIDATE
HEAD_SETUP
LOAD_K_CMD / LOAD_K_DATA
LOAD_V_CMD / LOAD_V_DATA
```

K/V 每个 head 各 512 byte，使用 8-beat burst 连续装载。

### B. Q tile 装载

```text
Q_TILE_SETUP
LOAD_Q_CMD / LOAD_Q_DATA
```

每次装载最多 8×8=64 byte。

### C. QK tile 计算

```text
QK_SETUP
QK_READ_ISSUE / QK_READ_CAPTURE
QK_MACRO_ISSUE / QK_MACRO_WAIT
QK_SCORE_STORE
QK_KEY_ADV
```

每个 8×8 Score tile 执行两个 macro slice。输出以 row-major 写入 Score scratch；key tile 从 0 增至 N-1。

### D. 逐行 Softmax

```text
SM_ROW_SETUP
SM_LOAD_ISSUE / SM_LOAD_CAPTURE
SM_START / SM_WAIT
SM_PROB_STORE
SM_ROW_ADV
```

每行从 Score scratch 读入 2048-bit `row_in`，复用原 Softmax。Probability 写入 Q/Probability scratch，同时执行：

```text
attention_sum[key] += probability[key]
```

### E. AV 计算

```text
AV_SETUP
AV_READ_ISSUE / AV_READ_CAPTURE
AV_MACRO_ISSUE / AV_MACRO_WAIT
AV_K_ADV
```

Probability 与 V 进入相同共享 macro，直到遍历全部 key。

### F. Context 写回

```text
CTX_STORE_CMD / CTX_STORE_DATA / CTX_STORE_WAIT
CTX_ROW_ADV
Q_TILE_ADV
HEAD_ADV
```

每个 query 行写 8 byte，即 2-beat burst；地址直接产生 token-major 布局。

### G. 热图统计写回

```text
SUM_STORE_CMD / SUM_STORE_DATA / SUM_STORE_WAIT
FINISH
```

只写 64 个 U32，共 64 beat。若 `aux0=0`，直接结束。

## 9. AXI 流量预算

当前单层注意力的主要中间流量：

```text
Score write/read       = 16,384 + 16,384 beats
Probability write/read =  4,096 +  4,096 beats
```

融合后不再出现这些外部访问。当前 TinyViT 融合操作自身约为：

```text
Q/K/V read       = 1,536 beats
Context write    =   512 beats
Attention sum    =    64 beats
```

即注意力阶段读写流量从约 43,008 beats 降为约 2,112 beats，下降约 95.1%。

静态中间缓冲区可删除：

```text
score_store        65,536 bytes
probability_store  16,384 bytes
context_head_store  2,048 bytes
```

新增 `attention_sum_store[64]` 共 256 byte，净减少 83,712 byte。

## 10. 性能与计数器

新增计数器：

| Offset建议 | 名称 | 含义 |
|---:|---|---|
| 0x58 | `PERF_FUSED_ATTN_ROWS` | 完成的 query×head 行数 |
| 0x5c | `PERF_SCORE_LOCAL_WORDS` | 未落外存的 Score S32 word 数 |
| 0x60 | `PERF_PROB_LOCAL_BYTES` | 未落外存的 Probability byte 数 |

融合模块仍应使 `PERF_SOFTMAX` 增加 `M×batch`，TinyViT 中仍为 256 行，保持现有 UART/DVI 统计语义。

建议 UART 新增：

```text
fused_attention_rows=256
score_local_words=16384
prob_local_bytes=16384
```

第一版性能验收目标：

- 总描述符从 15 降到 13；
- Attention 中间 AXI 流量下降至少 90%；
- 完整 SoC 周期低于 620,000；
- 10 个 logits 逐位一致；
- attention heatmap 与旧路径逐像素一致。

周期目标是工程目标而非预先保证；位精确和外存流量消除是强制验收项。

## 11. 软件设计

新增编译开关：

```c
#define TINYVIT_USE_FUSED_ATTENTION 1
```

新增调用：

```c
run_fused_attention(q_head, k_head, v_head,
                    context, attention_sum_store);
```

开启时替换：

```text
QK GEMM
run_softmax
AV GEMM
merge_heads
```

热图函数改为直接读取 64 项 column-sum，只保留 min/max 归一化：

```text
make_attention_map_from_sums(attention_sum_store, map)
```

关闭编译开关时保持原有三描述符路径，用于同一模型、同一 bit-exact 判据下的 A/B 消融。

## 12. 验证方案

### 模块级

新增 `lsme_fused_attention_tb.v`：

- 1/4 heads；
- M/N=1、7、8、9、64；
- 正负 Q/K/V；
- Score 极值和 Softmax tail；
- Context requantization 正负半值、饱和；
- attention_sum 与软件参考逐项比较；
- AXI backpressure 和 error 注入。

参考模型必须按原顺序执行 QK、原 Softmax 公式、Q7 Probability、AV 和 `requant_s8`，不能使用 real/浮点 Softmax。

### 执行引擎级

扩展 `lsme_exec_engine_tb`：

- operation=5 解码；
- word4=V、word15=attention_sum 地址；
- burst/macro owner 不冲突；
- user tag、softmax rows、fused rows、local word counter；
- descriptor count 正确。

### 整机级

保留旧路径和融合路径两个构建：

```text
TINYVIT_USE_FUSED_ATTENTION=0
TINYVIT_USE_FUSED_ATTENTION=1
```

强制比较：

- 10 个 logits；
- 64-byte Context；
- 64-byte DVI heatmap；
- predicted/expected；
- AXI read/write beats；
- CPU/engine cycles。

### 后端级

重点检查：

- macro/burst 多路器到 AXI Master 的组合路径；
- Softmax 复制后的 LUT/FF 增量；
- Score BRAM 和 K/V BRAM 是否正确推断；
- WNS≥0、DSP48=0、无 level>5 congestion。

若 macro/burst owner 多路器进入关键路径，应在 owner 边界增加一级请求寄存器，而不是使用 false path 或 pblock 掩盖。

## 13. PPA 预算

基于现有层次资源，第一版预算为：

| 资源 | 预算增量 |
|---|---:|
| LUT | +3,000～5,000 |
| FF | +2,000～3,500 |
| RAMB18 | +3～4 |
| DSP48 | 0 |

最大逻辑增量来自第二个 `lsme_softmax_core`。若最终 LUT 压力较大，再进行第二阶段重构，让普通 Softmax 描述符和融合注意力共享同一个 Softmax 实例；第一版不为节省约 2k LUT 而增加控制耦合和验证风险。

## 14. 决赛展示

展示只使用一条主线：

```text
旧：QK → SRAM Score → Softmax → SRAM Probability → AV
新：QK → on-chip Score → Softmax → AV → Context
```

屏幕或串口同时给出：

```text
descriptors:          15 → 13
score external words: 16384 → 0
prob external bytes:  16384 → 0
attention traffic:    -95.1%
logits bit-exact:      yes
heatmap bit-exact:     yes
DSP48:                 0
```

核心答辩表述：

> 本设计没有增加一个独立 Attention 黑盒，而是让 LoongArch LACC 描述符在同一条流式执行中复用 SME 风格的 ZA/MOPA、整数 Softmax 和片上 tile 状态，从体系结构层面消除注意力中间矩阵的外存物化。
