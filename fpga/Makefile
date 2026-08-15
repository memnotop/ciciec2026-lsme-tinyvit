.PHONY: project sim sim-rgb332-baseline-dvi sim-rgb332-fused-attention synth-rgb332-fused-attention-shared-softmax impl impl-board-stable impl-rgb332-holdfix impl-rgb332-baseline-dvi impl-rgb332-fused-attention impl-rgb332-fused-attention-force-incremental impl-rmsnorm-incremental impl-rmsnorm-force-incremental regional-baseline-rebuild bitstream

VIVADO ?= vivado

project:
	$(VIVADO) -mode batch -nolog -nojournal -source create_project.tcl

sim:
	$(VIVADO) -mode batch -nolog -nojournal -source run_sim.tcl

# 使用区域赛归档 V2 RTL 与当前 RGB332 DVI 的完整 SoC 回归。
sim-rgb332-baseline-dvi:
	$(VIVADO) -mode batch -nolog -nojournal -source run_sim_rgb332_baseline_dvi.tcl

# 融合 Attention 的完整 SoC 行为回归；固件需以 TINYVIT_USE_FUSED_ATTENTION=1 构建。
sim-rgb332-fused-attention:
	$(VIVADO) -mode batch -nolog -nojournal -source run_sim_rgb332_fused_attention.tcl

# 先生成共享 Softmax 融合核的综合网表，供后续固定外围的增量实现使用。
synth-rgb332-fused-attention-shared-softmax:
	$(VIVADO) -mode batch -nolog -nojournal -source run_synth_rgb332_fused_attention_shared_softmax.tcl

impl:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl.tcl

# 重新布局布线并执行后布线 hold 修复，作为实板交付 bit 的唯一实现入口。
impl-board-stable:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_board_stable.tcl

# 从 RGB332 已路由 checkpoint 进行定向 hold 修复；满足双裕量门槛才生成 bit。
impl-rgb332-holdfix:
	$(VIVADO) -mode batch -nolog -nojournal -source run_rgb332_postroute_holdfix.tcl

# 以已验证区域赛物理配置为基线，仅替换 RGB332 DVI 外设。
impl-rgb332-baseline-dvi:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_rgb332_baseline_dvi.tcl

# 从用户已实板验证成功的 RGB332 DVI checkpoint 增量实现融合 Attention 硬件。
impl-rgb332-fused-attention:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_rgb332_fused_attention.tcl

impl-rgb332-fused-attention-force-incremental:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_rgb332_fused_attention_force_incremental.tcl

# 以已知稳定的外部 SRAM/CPU 物理实现为参考，只重布新增的 RMSNorm 路径。
impl-rmsnorm-incremental:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_rmsnorm_incremental.tcl

# 匹配率略低于自动阈值时，强制复用稳定的 CPU/BaseRAM/UART 物理实现。
impl-rmsnorm-force-incremental:
	$(VIVADO) -mode batch -nolog -nojournal -source run_impl_rmsnorm_force_incremental.tcl

# 不含当前新增 RTL 的区域赛原始源码重建，用于板级启动二分。
regional-baseline-rebuild:
	$(VIVADO) -mode batch -nolog -nojournal -source run_regional_baseline_rebuild.tcl

bitstream:
	$(VIVADO) -mode batch -nolog -nojournal -source generate_bit.tcl
