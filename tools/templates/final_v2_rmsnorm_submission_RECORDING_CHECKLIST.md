# 正式远程录制检查清单

- [ ] 核对 `BUILD_MANIFEST.txt` 中 bit、preflight 和 remote bin 的 SHA-256。
- [ ] FPGA 配置为 `lsme_v2_rmsnorm_final.bit`，BaseRAM 写入偏移为 `0x0`。
- [ ] 先运行 `lsme_v2_rmsnorm_preflight.bin`，串口同时显示 `lacc=024040bf`、`csr=024040bf`、`LSME_V2_RMSNORM_PREFLIGHT_PASS`。
- [ ] 保持同一 bit，覆盖 BaseRAM 为 `tinyvit_v2_rmsnorm_final_remote.bin` 并复位。
- [ ] UART 显示 `TINYVIT_BOOT_V2_COMPACT`、`V2_CAP 024040bf 024040bf`、`TINYVIT_V2_PASS`。
- [ ] UART 指标包含 `d=15 m=12864 t=546 s=256 r=192`。
- [ ] DVI 同时显示输入、attention 热图、十类得分、性能计数和绿色 PASS。
- [ ] `SW[3:0]` 至少切换一次并等到新的 PASS；可选 `SW[15]` 自动轮播。
- [ ] 视频中注明 684,692 / 684,654 cycles 来自 SoC 仿真，不能表述成未经记录的实板周期。
- [ ] 视频中展示相对基线的 1,007,062 → 684,692 cycles，并展示 DSP=0、WNS/WHS=+0.330/+0.022 ns。
- [ ] 不使用历史 V1、stream-safe、v2-compat 或旧 remote-demo 目录的 bit/bin 作为本优化版展示文件。
