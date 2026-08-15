# RGB332 安全恢复包

这个包用于恢复“配置后串口、DVI 都无输出”的远程板。它刻意不包含尚未实板
验证的融合 Attention OP5 bitstream；该候选在实现时只获得 55.67% 单元匹配，
Vivado 已退化为全量布局布线，不能作为板端交付。

## 唯一有效组合

1. 配置 `00_rgb332_verified.bit`。
2. 将 `01_cifar_tinyvit_rgb332_stream.bin` 写入 **BaseRAM**，偏移必须为
   `0x00000000`。
3. 解除或触发 CPU 复位，等待 UART 首行：

```text
CIFAR32_TINYVIT_BOOT_V1_STREAM
```

4. 首个样例结束应出现：

```text
CIFAR32_RESULT expected=0(airplane) predicted=0(airplane) exact=1
CIFAR32_TINYVIT_STREAM_PASS
```

`SW[3:0]` 选择 10 个 CIFAR-10 样例；`SW[15]` 自动轮播。DVI 显示 32x32
RGB332 输入、8x8 Attention 热图、十分类得分、性能计数及 PASS 状态。

## 验证边界

- `00_rgb332_verified.bit` 的 SHA256 是
  `a4ee58f832553fa4826de91ac7cb604ff64efaeb87effa834124719d486e953e`，来自此前
  已实板启动的 RGB332-DVI 物理基线。
- 本包固件已使用同一 `02_cifar_tinyvit_rgb332_stream_axi_ram.mif` 完成完整 SoC
  仿真：10 个 logits 逐项一致，`exact=1`，DVI 发布完成，周期数为 `2,832,193`。
- `02_*.mif` 供本地 FPGA 仿真或重新综合使用；远程平台按 `.bin` 写 BaseRAM。

不要将本包 `.bin` 与融合 Attention 的 `.bit` 混用，也不要使用
`project_rgb332_fused_attention_shared_force_incremental` 下的 bitstream。后者仍保留
为 RTL/仿真研究候选，待实现复用率和实板启动均重新验证后才会发布。
