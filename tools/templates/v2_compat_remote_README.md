# LSME-128I V2 cached 远程兼容演示包

这个包只用于 V2 cached 的仿真复现和实板故障定位，**不再作为当前远程平台的
比赛演示包**。最近的远程展示已经观察到分类结果大面积错误；在完成
`lsme_v2_burst_diag.bin` 的目标实板验证前，请改用 `stream_safe_remote_20260813`
目录中的 V1 流式安全包。

它实际展示的硬件能力是：LoongArch `LACC` 自定义指令、64 路 INT8 MOPA、
SME 风格 Z/P/ZA 状态、8×8 macro tile、片上 A/B 缓存、AXI burst、Softmax、
VADD，以及 DVI 注意力热图和分类仪表盘。

> 边界必须说清：此包的三次 RMSNorm 使用 CPU 上的位精确定点回退，**不是**
> 硬件 RMSNorm；V2 cached burst 也只有理想 SRAM 仿真证据，不能把仿真中的
> `TINYVIT_V2_COMPAT_PASS` 当作远程实板正确性证据。

## 上传顺序

1. 如需复现 V2 故障，在 FPGA 配置区上传 `lsme_v2_cached_compat.bit`，等待平台完成配置。
2. 在存储写入区选择 **BaseRAM**，起始字节偏移填 `0x00000000`。
3. 首先写入 `lsme_v2_cached_compat_probe.bin` 并复位一次。UART 应出现：

   ```text
   LSME_V2_COMPAT_BOOT_PROBE
   V2C_PROBE lacc=02404088 csr=0240409f
   LSME_V2_COMPAT_BOOT_PROBE_PASS
   ```

4. 保持同一 `.bit`，以同一偏移写入
   `lsme_tinyvit_v2_cached_compat.bin`，再复位一次。
5. UART 仿真中应依次出现 `TINYVIT_BOOT_V2_COMPAT_SW_RMSNORM`、
   `V2C_CAP lacc=02404088 csr=0240409f` 和
   `TINYVIT_V2_COMPAT_PASS`。若目标实板输出的十个 logits 或分类与预期不符，
   立即停止，不要录制，也不要以此包制作结果截图。

网页的写入偏移是 `0x00000000`；CPU 链接地址 `0x1c000000` 不能填入该字段。

## 交互演示

- `SW[3:0]`：选择 `0`～`9` 的真实 Fashion-MNIST 样例；每次切换都会重新推理。
- `SW[15]=1`：每 1.8 秒自动轮播一个样例，适合录制 1 分钟视频。
- LED：预测类别的 one-hot 指示；数码管：期望类别和预测类别。

现场正确性回归请改用 `stream_safe_remote_20260813/README.md` 中的上传流程。

## 已验证证据

`tinyvit_v2_cached_compat_sim.log` 是本包固件与旧 V2 cached RTL 的完整 SoC
行为仿真记录，最终输出：

```text
V2C_RESULT expected=0 predicted=0 exact=1
V2C_METRIC cycles=1007050 desc=12 mopa=12864 tiles=546 softmax=256 hw_rms_rows=0 speedup_vs_v1=1.815x
TINYVIT_V2_COMPAT_PASS
```

这些周期和加速比来自完整 SoC 行为仿真；远程录像中可以展示同一固件的实时
UART/DVI 结果，但不能把 `1,007,050 cycles` 说成远程板实测，除非另行采集并
保存该板的测量证据。

`bitstream_lineage.md` 记录了该 `.bit` 与恢复成功位流、旧 V2 RTL 和验证日志
之间的对应关系；`verified_metrics.md` 和 `video_script_60s.md` 可直接用于
答辩材料和录屏。

## 不应混用的文件

- 不要把本目录 `.bin` 与 `final_remote_demo_20260813/` 的 V2+硬件 RMSNorm
  `.bit` 混用。
- 不要把本目录 `.bit` 与该目录的 V2+硬件 RMSNorm `.bin` 混用。
- 本目录所有主文件均由 `SHA256SUMS` 保护，上传前可执行
  `sha256sum -c SHA256SUMS`。
