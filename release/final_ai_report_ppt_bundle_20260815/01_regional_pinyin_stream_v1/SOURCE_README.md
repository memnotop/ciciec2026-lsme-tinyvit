# LSME TinyViT 远程 DVI 中文串口演示包

本目录是同一次构建生成的远程 FPGA 演示文件，面向 XC7A200T FBG676 和 800x600 DVI 平台。

## 文件

| 文件 | 用途 |
|---|---|
| `lsme_tinyvit_xai_zh_64lane.bit` | FPGA 配置文件，含 LSME-128I、TinyViT 和 DVI XAI 仪表盘 |
| `lsme_tinyvit_xai_zh_64lane.bin` | 与该 bitstream 配套的裸机软件镜像 |
| `lsme_tinyvit_xai_zh_stream_v1.bin` | **实板推荐**：强制使用已通过自检的 V1 流式 GEMM |
| `lsme_tinyvit_xai_zh_stream_v1_boot.bin` | 同一 V1 演示，入口第一行输出 `TINYVIT_BOOT_STREAM_V1`，用于排查镜像是否启动 |
| `lsme_tinyvit_xai_pinyin_stream_v1.bit` | **拼音串口最终版 bitstream**，与下方拼音 `.bin` 配套 |
| `lsme_tinyvit_xai_pinyin_stream_v1.bin` | **拼音串口最终版软件**，全部串口说明使用 ASCII 拼音 |
| `tinyvit_demo_pinyin_stream_v1.elf` | 拼音串口最终版调试 ELF |
| `tinyvit_pinyin_stream_v1_simulate.log` | 拼音版本完整 SoC 仿真日志，结尾为 `TINYVIT_DEMO_PASS` |
| `tinyvit_demo_stream_v1.elf` | V1 稳定演示的调试 ELF |
| `tinyvit_demo_stream_v1_boot.elf` | 带启动标志版本的调试 ELF |
| `tinyvit_stream_v1_simulate.log` | V1 完整 SoC 仿真日志，结尾为 `TINYVIT_DEMO_PASS` |
| `axi_ram.mif` | 行为仿真/片上 SRAM 初始化镜像 |
| `tinyvit_demo_zh.elf` | 带符号的调试 ELF |
| `lsme_selftest_stream.bin` | 诊断固件：强制 V1 流式 GEMM，不需要重新下载 bit |
| `lsme_selftest_stream_barrier_v2.bin` | 同一诊断固件的明确版本名，已加入 CPU/LSME 共享内存屏障 |
| `lsme_selftest_stream.elf` | V1 诊断固件调试 ELF |
| `timing_summary.rpt` | 实现后的时序报告 |
| `drc.rpt` | 实现后的 DRC 报告 |
| `dsp_utilization.rpt` | 资源报告，确认 DSP48=0 |
| `SHA256SUMS` | 文件完整性校验 |

## 远程平台操作

1. 下载 `lsme_tinyvit_xai_zh_64lane.bit` 并配置 FPGA。
2. 在网页的存储选择中选 `BaseRAM`，起始地址（字节偏移）填 `0x00000000`，优先写入同目录的 `lsme_tinyvit_xai_zh_stream_v1.bin`。
   `0x1c000000` 是 CPU 运行时的链接地址，不是网页存储偏移字段。
3. 连接 800x600 DVI 显示和 115200 8N1 UART。
4. 解除复位，等待串口出现 `TINYVIT_DEMO_PASS`。
5. 修改拨码开关 `SW[3:0]`，选择 0~9 号样例；样例变化后会自动重新推理。

DVI 显示输入图像、注意力热图、十类得分条、预测结果和性能计数器。串口输出中文解释，并保留 `TINYVIT_DEMO_PASS`/`TINYVIT_DEMO_FAIL` 英文标志，便于现场检索。

当前远程实板的 V1 流式自检已经完整通过；V2 cached GEMM 仍在排查，因此比赛演示优先使用 `stream_v1.bin`。该软件与本目录的 bitstream 配套，不需要重新生成或重新上传另一份 bit 文件。

如果 `stream_v1.bin` 没有任何串口输出，可先使用 `stream_v1_boot.bin`。复位后应立即看到 `TINYVIT_BOOT_STREAM_V1`；若仍没有，说明网页没有把该镜像写入 BaseRAM 或 CPU 没有复位运行。

## 描述符故障诊断

若 `lsme_selftest.bin` 报告 `low-level SMOPA pass` 但描述符矩阵错误，先保持同一个 bitstream，
只把 `lsme_selftest_stream_barrier_v2.bin` 写入网页中的 BaseRAM 偏移 `0x00000000` 后复位：

- V1 也失败：优先检查板级 BaseRAM/AXI 读写时序或地址映射；
- V1 通过：问题集中在 V2 cached GEMM 的突发搬运或缓存路径，TinyViT 演示暂不能判定通过。
