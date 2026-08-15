# 验证口径

本目录的正确性不是只看分类标签，而是依次满足以下三层证据：

1. `verification/final_v2_rmsnorm_rtl.log` 以 `LSME_RTL_REGRESSION_PASS` 结束，覆盖 MOPA、V2 GEMM、Softmax、RMSNorm、AXI、执行引擎、SoC 顶层和 DVI。
2. `verification/final_v2_rmsnorm_preflight_soc.log` 以 `LSME_V2_RMSNORM_PREFLIGHT_PASS` 结束。预检程序要求 LACC 与 CSR capability 都为 `0x024040bf`，并逐元素校验 8x8x32 V2 Cached Macro8 GEMM 与 64x32 RMSNorm。
3. `verification/final_v2_rmsnorm_full_soc.log` 以 `TINYVIT_DEMO_PASS` 结束，并要求 `logits=10/10 bit_exact=yes classification=yes rmsnorm_rows=192`。这说明三个 RMSNorm 调用均走了硬件路径，最终十个 logits 与参考结果完全一致。
4. `verification/final_v2_rmsnorm_impl.log` 记录 DSP48=0 和正 setup slack；`verification/final_v2_rmsnorm_bitstream.log` 记录 `Bitgen Completed Successfully`。对应 routed 报告显示 50 MHz 下 WNS/WHS 为 +0.330/+0.022 ns，setup/hold 失败端点均为 0。

远程平台上先执行预检，再执行正式演示，是为了把“bit/bin 不匹配、未更新 bit、AXI 路径异常”与模型计算错误分开定位。正式演示的 `TINYVIT_V2_PASS` 只在预检通过后才具有提交意义。
