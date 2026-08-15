# V2 cached 兼容演示：60 秒录制分镜

录像原则是：先证明远程板真实运行，再展示交互结果，最后给出性能和结构证据。
全程保留 DVI 与 UART 同屏；性能数字必须标注为“完整 SoC 仿真”。

| 时间 | 画面与操作 | 口播/字幕建议 |
|---|---|---|
| 0–7 s | 已配置完成后，写入 probe 并复位；UART 出现 `LSME_V2_COMPAT_BOOT_PROBE_PASS`。 | “先用 LoongArch 自定义 LACC 指令和 AXI CSR 双路径读取能力字，确认 64 路 V2 cached 引擎已启动。” |
| 7–15 s | 写入完整兼容固件并复位；显示 `TINYVIT_BOOT_V2_COMPAT_SW_RMSNORM`、`02404088 / 0240409f`。 | “这是 LSME-128I 的 V2 cached 执行路径。这里明确标注：本次兼容展示的 RMSNorm 是位精确软件回退。” |
| 15–27 s | 展示 DVI：输入图、8×8 attention、十类 score、绿色正确状态；UART 显示 `V2C_RESULT`。 | “模型不是单一 GEMM：输入经过投影、四头注意力、Softmax、残差和分类，热图和十类分数都由这次推理产生。” |
| 27–38 s | 手动切 `SW[3:0]`：`0 → 7 → 2`；每次等 PASS。 | “拨码切换真实样例，图像、注意力、类别条、LED、数码管和 UART 同步刷新，证明不是预录画面。” |
| 38–46 s | 开启 `SW[15]` 自动轮播；UART/DVI 连续变化。 | “自动轮播用于持续展示交互式端到端推理。” |
| 46–55 s | 放大 UART 性能行或叠加数据卡：`12 desc / 12864 MOPA / 546 tiles / 256 Softmax / 1.815x`。 | “完整 SoC 仿真中，V2 cached 将 V1 的 1,827,549 cycles 降为 1,007,050 cycles，保持十个 logits 逐位一致，系统级加速 1.815 倍。” |
| 55–60 s | 展示 PPA 卡并回到 `TINYVIT_V2_COMPAT_PASS`。 | “硬件采用 64 路 INT8 MOPA、8×8 宏瓦片和片上 A/B 缓存，DSP48 为零且时序满足。下一版硬件 RMSNorm 已单独完成 RTL/仿真，本视频先以稳定 V2 核心做远程演示。” |

录制时不要把上传或等待页面剪成“实时加速”；每次拨码变化后应等待下一次
`TINYVIT_V2_COMPAT_PASS` 再继续。
