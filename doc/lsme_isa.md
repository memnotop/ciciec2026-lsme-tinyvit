# LSME-128I V2 指令、描述符与 MMIO ABI

## 1. 自定义指令格式

LoongArch32R 解码器使用 `inst[31:28] = 4'b1100` 作为 LACC 自定义前缀：

```text
31          28 27 25 24    22 21          15 14       10 9         5 4       0
+--------------+-----+---------+--------------+-----------+-----------+---------+
|     1100     | RSV | command |     imm      |    rk     |    rj     |   rd    |
+--------------+-----+---------+--------------+-----------+-----------+---------+
```

- `command`：8 个 LSME 命令之一；
- `imm`：命令相关 7-bit 立即数；
- `rj/rk`：源寄存器；
- `rd`：返回值寄存器；
- 软件 ABI 使用 `a0/r4`、`a1/r5` 传参并从 `a0/r4` 取返回值。

汇编器尚无助记符支持，`sdk/software/bsp/drivers/lsme_lacc.S` 使用 `.word` 封装为 C 函数。

## 2. 命令

| command | 名称 | 语义 |
|---:|---|---|
| 0 | CTRL | 查询能力、streaming 开关、清计数器 |
| 1 | LDZ | 从内存加载一个 128-bit Z |
| 2 | PSET | 设置一个 16-bit P |
| 3 | ZERO | 清零 ZA 或从 S32 bias 广播初始化 |
| 4 | SMOPA | 有符号 INT8 外积累加 |
| 5 | STZA | 以 S32 或重量化 INT8 存储 ZA |
| 6 | EXEC | 异步启动一个 64-byte 描述符 |
| 7 | WAIT | 等待描述符结束并返回错误码 |

### CTRL

| imm | 操作 | 返回值 |
|---:|---|---|
| 0 | query | V2 为 `{0x02, lanes, 0x40, 0xbf}`；64 路为 `0x024040bf`。低级 LACC 查询与 AXI CSR 能力字保持一致 |
| 1 | streaming enable | 0 |
| 2 | streaming disable | 0 |
| 3 | 清 ZA/error/MOPA/active counters | 0 |
| 4 | read MOPA count | 32-bit count |
| 5 | read active cycles | 32-bit count |

### LDZ

- `imm[2:0]`：Z 编号；
- `imm[3]`：4×4 byte transpose；
- `rj`：4-byte 对齐基地址；
- `rk[15:0]`：四个 32-bit 读取之间的 byte stride，0 解释为 4。

### PSET

- `imm[1:0]`：P 编号；
- `rj[15:0]`：谓词值。

### ZERO / BIAS

- `imm[6]=0`：`imm[3:0]` 是 ZA 清零掩码；
- `imm[6]=1`：从 `rj` 读取 4 个 S32 bias，并广播到 `imm[1:0]` 选择的 ZA 四行。

### SMOPA

选择字位于 `rj`：

| 位 | 字段 |
|---|---|
| 2:0 | Zn |
| 5:3 | Zm |
| 7:6 | Pn |
| 9:8 | Pm |
| 11:10 | ZA |

### STZA

- `imm[1:0]`：ZA 编号；
- `imm[2]`：0=S32，1=INT8；
- `imm[3]`：INT8 路径启用 ReLU；
- `rj`：目标基地址；
- `rk[15:0]`：目标 row stride；
- `rk[20:16]`：对称舍入右移位数。

INT8 路径执行 sign/magnitude 对称舍入，然后饱和到 `[-128,127]`。

### EXEC / WAIT

- `EXEC rj`：提交 `rj` 指向的 64-byte 对齐描述符，接收成功后立即返回；
- `WAIT`：等待完成，低 8 bit 返回 0 或错误码。

## 3. 64-byte 描述符

软件结构定义在 `sdk/software/bsp/include/lsme.h`。

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | `op_flags` | bits 7:0 operation，bits 31:8 flags |
| 1 | `src0` | A / score / vector A 地址 |
| 2 | `src1` | B / vector B 地址 |
| 3 | `dst` | 输出地址 |
| 4 | `bias` | S32 bias 地址 |
| 5 | `m_n` | low16=M，high16=N |
| 6 | `k_batch` | low16=K，high16=batch；batch=0 解释为 1 |
| 7 | `src0_row_stride` | byte stride |
| 8 | `src1_row_stride` | byte stride |
| 9 | `dst_row_stride` | byte stride |
| 10 | `src0_batch_stride` | byte stride |
| 11 | `src1_batch_stride` | byte stride |
| 12 | `dst_batch_stride` | byte stride |
| 13 | `quant_head` | out shift、score shift、head count、head dim |
| 14 | `user_tag` | 软件标签，完成后可读 |
| 15 | `aux0` | V2 签名与 GEMM execution mode |

`quant_head` byte 布局：

```text
31        24 23        16 15         8 7          0
+-----------+------------+------------+------------+
| head_dim  | head_count | score_shift| out_shift  |
+-----------+------------+------------+------------+
```

### Operation

| 值 | 操作 | 输入/输出 |
|---:|---|---|
| 1 | GEMM | INT8 A/B，S32 或 INT8 output |
| 2 | SOFTMAX | S32 score，Q7 unsigned byte output |
| 3 | VECTOR_ADD | S32 或饱和 INT8 add，支持多行和原位操作 |
| 4 | RMSNORM | INT8 行输入与 gain，输出位精确 INT8 RMSNorm |

RMSNorm 使用 `M=rows`、`N=columns`、`src0=input`、`src1=gain`、`dst=output`。`quant_head[7:0]` 是输入 fraction bits，`quant_head[15:8]` 是 gain fraction bits；当前每行最多 64 个元素。

### Flags

| bit | 名称 | 作用 |
|---:|---|---|
| 0 | `TRANS_B` | B 在内存中为 N×K |
| 1 | `OUTPUT_INT8` | GEMM/VADD 输出 INT8 |
| 2 | `BIAS` | GEMM 初始化 ZA 时加入 S32 bias |
| 3 | `RELU` | INT8 输出或 VADD 启用 ReLU |
| 4 | `ACCUMULATE` | ABI 保留，当前返回 unsupported |
| 5 | `HEAD4` | 4-head 调度提示 |
| 6 | `PER_CHANNEL_SHIFT` | ABI 保留，当前返回 unsupported |

## 4. V2 GEMM 选择

`aux0` 布局：

```text
31                    16 15             8 7              0
+-----------------------+----------------+----------------+
| magic = 0x5632 ('V2') | reserved = 0   | execution mode |
+-----------------------+----------------+----------------+
```

| Mode | 名称 | 行为 |
|---:|---|---|
| 0 | AUTO | 当前自动选择 V2 cached GEMM |
| 1 | CACHED | 强制 V2 cached GEMM |
| 2 | STREAM | 强制旧 V1 4×4 流式 GEMM |

没有 `0x5632` 签名的旧描述符自动保持 V1 行为。V2 要求地址和 row stride 4-byte 对齐，支持正常 B/`TRANS_B`、INT8/S32 输出、bias、ReLU、batch 和尾块，容量上限为 `M≤64、N≤128、K≤64`。

### GEMM 数据布局

- 默认 A 为 M×K row-major，B 为 K×N row-major；
- `TRANS_B=1` 时 B 为 N×K row-major，适合 Q×Kᵀ；
- 尺寸不必是 4 或 8 的倍数，谓词自动屏蔽尾块；
- bias 按 N 方向排列；
- V2 每个 batch 先缓存 A/B，再执行 8×8 宏瓦片。

### Softmax 定点格式

- 每行最多 64 个 S32 score；
- 先减去行最大值，再按 `score_shift` 压缩差值；
- 指数采用 32-entry base-2 fractional ROM；
- 归一化使用 Q16 reciprocal；
- 输出范围为 `[0,127]`，用于后续 INT8 AV GEMM。

## 5. MMIO

CPU 使用 DMW uncached 地址 `0xbf30_0000`，对应物理地址 `0x1f30_0000`。

| Offset | 名称 | R/W | 说明 |
|---:|---|---|---|
| 0x00 | ID | R | `0x4c534d45`，ASCII `LSME` |
| 0x04 | CAPABILITY | R | `{version=2, lanes, max_cached_K=64, features=0xbf}`，bit5=RMSNorm |
| 0x08 | CONTROL | W | bit0 start，bit1 clear |
| 0x0c | STATUS | R | busy/done/error/schedule/error code |
| 0x10 | DESCRIPTOR | R/W | 描述符地址 |
| 0x14 | USER_TAG | R | 完成标签 |
| 0x18 | PERF_DESC | R | 完成描述符数量 |
| 0x1c | PERF_MOPA | R | MOPA 数量 |
| 0x20 | PERF_ACTIVE | R | 低级核心活动周期 |
| 0x24 | PERF_MEMORY | R | V1 描述符直接内存 word 数 |
| 0x28 | PERF_TILES | R | V1 4×4 或 V2 8×8 GEMM 调度瓦片数 |
| 0x2c | PERF_SOFTMAX | R | Softmax 行数 |
| 0x30 | DEBUG_CONTROL | R/W | ZA 与元素选择 |
| 0x34 | DEBUG_DATA | R | 所选 ZA S32 元素 |
| 0x38 | PERF_ENGINE | R | descriptor engine busy cycles |
| 0x3c | PERF_AXI_READ | R | AXI read data beats |
| 0x40 | PERF_AXI_WRITE | R | AXI write data beats |
| 0x44 | PERF_COMPUTE | R | V2 macro compute-active cycles |
| 0x48 | PERF_STALL | R | V2 load/store memory-stall cycles |
| 0x4c | PERF_OVERLAP | R | compute 与 memory 同时活动周期 |
| 0x50 | LAST_DESC | R | 最近一个完成/失败描述符周期 |
| 0x54 | PERF_RMSNORM | R | 完成的 RMSNorm 行数 |

调度模式为 `K_SPLIT=0`、`TILE8=1`、`HEAD4=2`、`MACRO8=3`。V2 GEMM 报告 `MACRO8`。

## 6. AXI burst 契约

V2 使用 32-bit INCR burst，每条命令 1～8 beats、单 outstanding。读端支持连续一拍一个 beat并在反压时保持响应；写端分别握手 AW/W，并在 B response 后完成命令。V1 低级访存仍使用同一主机的兼容单 word 端口。

## 7. 地址与一致性

LSME 把 `0xa0000000～0xbfffffff` 的 DMW uncached 地址归一为物理地址。CPU 与加速器共享的描述符和中间缓冲区必须通过 `lsme_uncached_ptr()` 访问，避免 D-cache 脏数据对 AXI 主机不可见。

模型常量在启动阶段、Cache 开启前复制到 SRAM；融合 QKV 参数也在推理计时区之前准备并通过 `dbar` 发布。

## 8. 错误码

| 值/范围 | 含义 |
|---|---|
| 0x01 | 非法低级命令 |
| 0x02 | 非法寄存器索引（预留） |
| 0x03 | 地址未 4-byte 对齐 |
| 0x04 | 低级内存访问错误 |
| 0x10 | 描述符读取错误 |
| 0x11 | 非法 operation |
| 0x12 | 非法维度/stride |
| 0x13 | 暂不支持的 flag |
| 0x14 | 低级核心执行错误 |
| 0x15 | V1 数据内存访问错误 |
| 0x17 | V2 容量或对齐不满足 |
| 0x18 | V2 burst/DMA response 错误 |
| 0x20 | 加速器忙 |
