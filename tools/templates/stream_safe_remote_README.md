# LSME-128I 实板安全演示包

这个包用于当前远程 FPGA 的正确性回归和录制演示。它保留同一份已经在远程
实板通过的配置位流，但把 TinyViT 的所有 GEMM 固定到 `mode=2` 的 V1 流式
路径；三次 RMSNorm 使用软件位精确回退。

## 为什么使用这个包

此前的 V2 cached 兼容固件在理想 SoC 仿真中逐位通过，但新的远程展示出现了
大面积错误。V2 cached/burst 路径因此暂时标记为“实板待排查”，不应作为比赛
录屏固件。V1 安全路径的完整 SoC 仿真输出十个 logits 全部一致，并且使用了同一
份历史实板通过 bitstream。

这不是放弃自主 IP：演示仍经过 LoongArch `LACC`、64 路 INT8 MOPA、Softmax、
VADD、DVI 注意力热图和性能计数；只是暂时避开尚未完成板级时序验证的缓存突发
搬运层。

## 上传顺序

1. 配置 `lsme_stream_safe.bit`，等待 FPGA 配置完成。
2. 在存储区选择 **BaseRAM**，字节偏移填写 `0x00000000`。
3. 上传 `tinyvit_stream_safe.bin` 并复位一次。
4. UART 应出现下面的顺序，且样例 0 应得到 `expected=0 predicted=0 exact=1`：

   ```text
   TINYVIT_BOOT_STREAM_SAFE_SW_RMSNORM
   STREAM_SAFE_CAP lacc=02404088 csr=0240409f
   STREAM_SAFE_STAGE=3 XAI DVI=published heatmap=8x8 classes=10
   STREAM_SAFE_RESULT expected=0 predicted=0 exact=1
   TINYVIT_STREAM_SAFE_PASS
   ```

网页的写入偏移是 `0x00000000`；`0x1c000000` 是 CPU 链接地址，不能填到网页
偏移字段。

## 录制操作

- `SW[3:0]` 选择 0～9 的真实样例；先切换 `0 -> 7 -> 2`，观察 UART、LED、数码管
  和 DVI 同步变化。
- `SW[15]=1` 打开 1.8 秒自动轮播，适合录制约 1 分钟视频。
- DVI 的 PASS 灯只有在本次 logits 逐位正确且分类正确时才会亮；UART 是主要
  证据，DVI 窗口若未被远程平台转发不影响算子验证。

## V2 burst 诊断

`lsme_v2_burst_diag.bin` 不是演示固件。保持同一 `.bit`，单独上传它可以分别
运行 8×8×32 的 V1 与 V2 GEMM，并报告首个错误位置以及 AXI read/write beat
计数。只有它在目标实板输出 `LSME_V2_BURST_DIAG_PASS` 后，才重新考虑启用
V2 cached TinyViT。

## 验证边界

- `tinyvit_stream_safe_sim.log`：旧 V2 RTL + 完整 SoC 仿真，包含十个 logits。
- `lsme_v2_burst_diag_old_v2_sim.log`：V1/V2 burst 对照仿真；当前仿真均通过，
  但不替代实板验证。
- `.bit` 是历史远程实板通过位流的逐字副本，SHA-256 见 `SHA256SUMS`。
