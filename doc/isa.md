# 指令与描述符

LoongArch32R 使用 `1100` 前缀识别 LACC 自定义指令。软件通过封装汇编函数调用，
不依赖编译器新增助记符。

| 指令 | 功能 |
|---|---|
| `LDZ` | 从内存装载 128-bit Z 向量 |
| `PSET` | 设置 16-bit 谓词 |
| `ZERO` | 清零或以 bias 初始化 ZA |
| `SMOPA` | 有符号 INT8 外积累加 |
| `STZA` | 以 S32 或 INT8 写回 ZA |
| `EXEC` | 异步提交 64-byte 描述符 |
| `WAIT` | 等待描述符完成并返回错误码 |

描述符以 16 个 32-bit word 表示：

```text
op/flags | src0 | src1 | dst | bias
M/N      | K/batch | row stride x3 | batch stride x3
quantization/head fields | user tag | auxiliary field
```

当前高层操作包括 INT8/S32 GEMM、S32 到 Q7 的整数 Softmax，以及饱和 INT8 VADD。
共享缓冲区使用非缓存地址，保证 CPU 与 AXI 主机访问同一份数据。
