.PHONY: software software-compact software-v2-compat software-stream-safe software-cifar software-cifar-fused-attention boot-heartbeat boot-probe boot-probe-v2-compat burst-diag preflight-v2-rmsnorm rtl-test quant-eval project sim sim-compact sim-rgb332-baseline-dvi sim-rgb332-fused-attention synth-rgb332-fused-attention-shared-softmax impl impl-board-stable impl-rgb332-holdfix impl-rgb332-baseline-dvi impl-rgb332-fused-attention impl-rgb332-fused-attention-force-incremental impl-rmsnorm-incremental impl-rmsnorm-force-incremental regional-baseline-rebuild bitstream clean-software remote-demo remote-recovery remote-v2-compat remote-v2-zerocopy remote-stream-safe remote-cifar final-regression final-submission board-startup-diagnostic

PYTHON ?= python3

software:
	$(MAKE) -C sdk/software/examples/tinyvit_demo \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 保留完整 V2 推理和 DVI，仅缩减串口文案，供存在镜像容量限制的远程平台使用。
software-compact:
	$(MAKE) -C sdk/software/examples/tinyvit_remote \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 使用已实板验证的 V2 cached 位流的兼容固件：仅 RMSNorm 为软件定点回退。
software-v2-compat:
	$(MAKE) -C sdk/software/examples/tinyvit_v2_compat \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# V1 流式安全演示：用于实板正确性回归和远程录屏，避免未验证的 V2 burst 路径。
software-stream-safe:
	$(MAKE) -C sdk/software/examples/tinyvit_stream_safe \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 更大测试集：真实 CIFAR-10 RGB 输入、两层 Transformer；复用稳定 V1 Stream 位流。
software-cifar:
	$(MAKE) -C sdk/software/examples/cifar_tinyvit_demo \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 生成与融合 Attention 硬件匹配的固件；不能用于旧的分解 Attention 位流。
software-cifar-fused-attention:
	$(MAKE) -C sdk/software/examples/cifar_tinyvit_demo clean
	$(MAKE) -C sdk/software/examples/cifar_tinyvit_demo \
		LA32RSOC_WINDOWS_HOME=$(CURDIR) TINYVIT_USE_FUSED_ATTENTION=1

# 不访问 LSME 的最小心跳：用于区分板级启动问题与加速器/推理问题。
boot-heartbeat:
	$(MAKE) -C sdk/software/examples/lsme_boot_heartbeat \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 小型启动探针：先确认当前 V2 bitstream 能启动 CPU、输出 UART 并读回 LSME 能力字。
boot-probe:
	$(MAKE) -C sdk/software/examples/lsme_v2_boot_probe \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 已验证 V2 cached 位流的精确能力字探针（0x02404088 / 0x0240409f）。
boot-probe-v2-compat:
	$(MAKE) -C sdk/software/examples/lsme_v2_compat_boot_probe \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 同一 8x8x32 GEMM 分别运行 V1 stream 和 V2 cached，用于定位 burst 数据通路。
burst-diag:
	$(MAKE) -C sdk/software/examples/lsme_v2_burst_diag \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

# 正式提交前的独立板端预检：V2 Cached Macro8 与硬件 RMSNorm 都逐元素比对。
preflight-v2-rmsnorm:
	$(MAKE) -C sdk/software/examples/lsme_v2_rmsnorm_preflight \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

clean-software:
	$(MAKE) -C sdk/software/examples/tinyvit_demo clean

rtl-test:
	tools/run_rtl_tests.sh

quant-eval:
	$(PYTHON) tools/evaluate_quantized_tinyvit.py --samples 10000

project:
	$(MAKE) -C fpga project

sim: software
	$(MAKE) -C fpga sim

sim-compact: software-compact
	$(MAKE) -C fpga sim

sim-rgb332-baseline-dvi: software-cifar
	$(MAKE) -C fpga sim-rgb332-baseline-dvi

sim-rgb332-fused-attention: software-cifar-fused-attention
	$(MAKE) -C fpga sim-rgb332-fused-attention

synth-rgb332-fused-attention-shared-softmax:
	$(MAKE) -C fpga synth-rgb332-fused-attention-shared-softmax

impl:
	$(MAKE) -C fpga impl

impl-board-stable:
	$(MAKE) -C fpga impl-board-stable

impl-rgb332-holdfix:
	$(MAKE) -C fpga impl-rgb332-holdfix

impl-rgb332-baseline-dvi:
	$(MAKE) -C fpga impl-rgb332-baseline-dvi

impl-rgb332-fused-attention:
	$(MAKE) -C fpga impl-rgb332-fused-attention

impl-rgb332-fused-attention-force-incremental:
	$(MAKE) -C fpga impl-rgb332-fused-attention-force-incremental

# 以已验证的 SRAM/CPU routed checkpoint 为增量参考生成最小 RMSNorm 板端候选。
impl-rmsnorm-incremental:
	$(MAKE) -C fpga impl-rmsnorm-incremental

impl-rmsnorm-force-incremental:
	$(MAKE) -C fpga impl-rmsnorm-force-incremental

regional-baseline-rebuild:
	$(MAKE) -C fpga regional-baseline-rebuild

bitstream:
	$(MAKE) -C fpga bitstream

# 只重编译固件并收集已经通过实现的 bitstream/报告，适合每次录屏前执行。
remote-demo:
	tools/create_final_remote_demo.sh

# 当前 V2+RMSNorm 的 probe 在远程板无首行输出时，使用历史已实板验证的
# V1 流式位流/固件恢复 UART、DVI 与演示链路；该目标不替代 V2 的验证。
remote-recovery:
	tools/create_remote_recovery_package.sh

# 生成“已验证 V2 cached 硬件 + 软件 RMSNorm”远程演示包。
remote-v2-compat:
	tools/create_v2_compat_remote_package.sh

# 固定使用已实板验证的区域赛 V2 bit，仅更新经过 SoC 回归的描述符零拷贝固件。
remote-v2-zerocopy:
	tools/create_v2_zerocopy_remote_package.sh

# 生成仅包含实板稳定 V1 流式路径的远程回归/演示包。
remote-stream-safe:
	tools/create_stream_safe_remote_package.sh

# 更大 CIFAR-10 RGB332 远程包；只替换已验证区域赛基线中的 DVI 外设。
remote-cifar:
	tools/create_cifar_tinyvit_remote_package.sh

# 依次运行 RTL、预检 SoC、完整 TinyViT 与精简远程固件的回归。
final-regression:
	tools/run_final_v2_rmsnorm_regression.sh

# 只接受上述回归日志和同一份 bit/bin，生成最终提交目录。
final-submission:
	tools/create_final_submission_package.sh

# 将已知可启动的区域赛 bit 与当前候选 bit 放入同一诊断包，按同一心跳固件二分。
board-startup-diagnostic:
	tools/create_board_startup_diagnostic.sh
