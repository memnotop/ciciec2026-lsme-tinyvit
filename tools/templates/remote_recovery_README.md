# 远程 FPGA 已知可启动恢复包

本目录只用于恢复远程平台的 UART、DVI 和演示链路。

- `lsme_remote_recovery_stream_v1.bit` 是已经在历史远程实板通过的 V1
  流式演示位流的逐字副本；SHA-256 为
  `6657d382705532f503a17c45e8258a3c1e58b994ee14b80cc995cb9bc7f1414a`。
- `lsme_remote_recovery_stream_v1.bin` 是与该位流配套的 ASCII 拼音串口
  固件；其启动标志为 `TINYVIT_BOOT_STREAM_V1`，完成标志为
  `TINYVIT_DEMO_PASS`。
- 此包不是 V2 + RMSNorm 的实板证据，不能用它宣称当前 RMSNorm 增强已经
  在远程板上通过。

## 恢复步骤

1. 上传 `.bit` 到 FPGA 配置区，并等待平台提示配置结束。
2. 在存储写入区选择 **BaseRAM**，起始字节偏移填写 `0x00000000`。
3. 上传 `.bin`，完成后只复位一次。
4. UART 应先出现 `TINYVIT_BOOT_STREAM_V1`，随后出现
   `TINYVIT_DEMO_PASS`；DVI 应出现输入、注意力热图、类别得分和性能栏。

如果这一份精确恢复包仍没有第一行输出，则问题已经不在当前 V2+RMSNorm
设计，而在本次远程会话的配置、BaseRAM 写入、复位或串口连接；此时应保留
该现象并重新申请/重置远程板，而不要继续替换模型固件。
