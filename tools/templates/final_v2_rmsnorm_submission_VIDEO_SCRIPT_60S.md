# 60 秒远程演示脚本（正式提交包）

录制前只使用同目录的 `lsme_v2_rmsnorm_final.bit`、`lsme_v2_rmsnorm_preflight.bin` 和 `tinyvit_v2_rmsnorm_final_remote.bin`。性能数字均为随包 SoC 仿真结果；除非现场另行读出可信计数器，不要称为“实板周期”。

| 时间 | 画面与操作 | 建议口播 | 要证明的能力 |
|---|---|---|---|
| 0–7 s | 显示本目录 README 的上传顺序；配置 bit 后先运行预检。UART 出现 capability `024040bf` 和 `LSME_V2_RMSNORM_PREFLIGHT_PASS`。 | “先以独立预检验证 LoongArch LACC、V2 Cached Macro8、AXI 和硬件 RMSNorm，避免 bit/bin 混配。” | 不是只靠最终分类结果掩盖底层错误。 |
| 7–18 s | 不重写 bit，只换远程演示 bin 并复位；同屏保留 DVI 与 UART。 | “现在运行完整 TinyViT：64 路 INT8 MOPA、Softmax、残差 VADD 和三次硬件 RMSNorm 都由描述符调度。” | 多模块 AI 执行子系统。 |
| 18–31 s | 停在一个样例，放大 DVI 的 INPUT、ATTENTION、CLASS SCORE 和绿色 PASS；UART 出现 `V2_METRIC c=684654 d=15 m=12864 t=546 s=256 r=192` 与 `TINYVIT_V2_PASS`。 | “一次推理包含 15 个描述符、12,864 次 MOPA、546 个 8×8 宏瓦片和 192 行硬件 RMSNorm；PASS 表示十个 logits 都与参考一致。” | 端到端、可解释、位精确。 |
| 31–42 s | 改一次 `SW[3:0]`，等待新一次 PASS；若网页支持高位开关，再打开 `SW[15]` 自动轮播。 | “拨码切换真实样例后，图像、热图、分类条和预测同步重算，而不是播放静态视频。” | 实时交互。 |
| 42–53 s | 打开 `LINEAGE.md` 或叠加性能卡：`1,007,062 → 684,692 cycles`，`1.4708x`。 | “相对分赛区决赛已展示的 V2 Cached Macro8，新增 SME 风格流式归约 RMSNorm 后，完整 SoC 仿真周期下降 32.01%。” | 优化相对基线有清晰、可比的收益。 |
| 53–60 s | 打开 routed report 的 WNS/WHS 与 DSP 行，最后回到 DVI PASS。 | “正式重新布线：46,924 LUT、21,803 FF、DSP48 为零，50 MHz 下 WNS/WHS 为 +0.330/+0.022 ns。共享迭代除法和平方根控制了面积与后端风险。” | PPA 与工程可实现性。 |

成片中至少保留 8 秒未剪切的 DVI 与 UART 同屏画面；切换样例后必须等到新的 `TINYVIT_V2_PASS` 再剪辑。
