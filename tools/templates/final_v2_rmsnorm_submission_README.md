# LSME-TinyViT 正式提交：V2 Cached Macro8 + 硬件 RMSNorm

这是相对于分赛区决赛版本的单一、可核验升级包。请只使用本目录内成对发布的 bit 与 bin，**不要**与历史 `remote_demo_zh_20260726`、`stream_safe` 或 `v2_compat` 目录中的任何文件混用。

## 优化内容

- 保留已在分赛区决赛成功展示的 V2 Cached Macro8 GEMM 主路径；其参考周期为 **1,007,062**。
- 新增 descriptor 化 INT8 RMSNorm，替代三个由 CPU 执行的归一化阶段；本次完整 TinyViT SoC 仿真周期为 **684,692**。
- 因而在相同模型、相同定点参数和相同 bit-exact logits 条件下，周期降低约 **32.0%**，即 **1.471x** 加速。

本包用于录制的精简固件在相同计算路径下为 684,654 cycles。两组数字都来自同一 RTL/固件版本的 SoC 仿真，不应在未完成现场预检前表述为实板测得值。

## 远程平台的唯一正确流程

1. 写入 `lsme_v2_rmsnorm_final.bit`，等待平台完成下载并复位。
2. 向 BaseRAM 偏移 `0x0` 写入 `lsme_v2_rmsnorm_preflight.bin`，复位并查看串口。
3. 必须看到 `LSME_V2_RMSNORM_PREFLIGHT_PASS`，且 capability 两处均为 `024040bf`。这一步同时验证 V2 Cached Macro8、硬件 RMSNorm、AXI 读写及精确舍入。
4. 不重写 bit，向同一 BaseRAM 偏移 `0x0` 写入 `tinyvit_v2_rmsnorm_final_remote.bin`，复位。
5. 串口应出现 `TINYVIT_V2_PASS`；DVI 应显示分类、attention 热图、性能计数和绿色 PASS。

若第 3 步失败，请停止第 4 步，保存完整串口输出、bit 的 SHA256 与平台写入日志。最常见原因是 bit/bin 来自不同目录或旧 bit 尚未被平台真正加载。

## 文件说明

- `lsme_v2_rmsnorm_final.bit`：唯一应下载的 FPGA bitstream。
- `lsme_v2_rmsnorm_preflight.bin`：先运行的独立硬件预检程序。
- `tinyvit_v2_rmsnorm_final_remote.bin`：1 分钟远程演示使用的精简固件。
- `tinyvit_v2_rmsnorm_final_full.bin`：含完整 UART 信息的固件，适合排障或答辩。
- `*_axi_ram.mif`：分别与对应 bin 同构的仿真初始化镜像；不用于远程平台手工写入。
- `verification/`：本包生成时的 RTL 与 SoC 仿真证据。
- `SHA256SUMS`、`BUILD_MANIFEST.txt`：上传前后用于确认文件未混用。

详细验证口径见 `VALIDATION.md`，与分赛区决赛的差异和版本沿革见 `LINEAGE.md`；
一分钟录制直接使用 `VIDEO_SCRIPT_60S.md` 与 `RECORDING_CHECKLIST.md`。
