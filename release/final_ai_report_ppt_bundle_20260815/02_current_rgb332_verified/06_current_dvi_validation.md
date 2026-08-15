# 当前 DVI 验证记录

当前 RGB332 DVI RTL 已在本次整理时重新执行独立 Verilator 测试：

```text
verilator --binary --timing -j 0 -Wall -Wno-fatal \
  --top-module axi_dvi_xai_tb \
  sim/axi_dvi_xai_tb.v rtl/ip/DVI/axi_dvi.v
```

结果：

```text
AXI_DVI_XAI_PASS
```

完整 SoC 仿真见同目录 `03_current_soc_sim.log`，其中同时出现：

```text
CIFAR32_STAGE=3 XAI DVI=published preview=32x32 RGB332 heatmap=8x8
CIFAR32_TINYVIT_STREAM_PASS
```

这两项分别验证 DVI MMIO/像素逻辑与端到端软件发布流程。它们不替代远程板的显示器
连接检查，但可排除 RTL 与软件发布协议的回归。
