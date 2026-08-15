# 面向实板稳定性的实现流程。
#
# 当前候选版的功能回归已通过，但 CPU->AXI FIFO 的最差 hold 裕量仅为 0.037 ns。
# 启动汇编在 UART 第一行之前就通过该路径清零 BSS/复制数据，因此这里必须优先
# 修复 hold，而不是只以 setup WNS 为唯一标准。该脚本不改变 RTL 或时钟频率；
# 只在后布线阶段让 Vivado 插入合法的物理延时并要求可复核的双裕量。

open_project project/Loongson_Soc.xpr

# 保持旧工程直接执行本脚本时也能找到新增的 RMSNorm 支持模块。
add_files -quiet ../rtl/ip/lsme/lsme_udiv32.v
add_files -quiet ../rtl/ip/lsme/lsme_isqrt32.v
add_files -quiet ../rtl/ip/lsme/lsme_rmsnorm_core.v
update_compile_order -fileset sources_1

reset_run synth_1
catch {set_property strategy Performance_Explore [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
       [get_runs impl_1]}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore \
       [get_runs impl_1]}

# 这一步专门处理短数据路径；它不放宽任何时序约束，也不改变功能。
catch {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true \
       [get_runs impl_1]}
catch {set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE \
       ExploreWithAggressiveHoldFix [get_runs impl_1]}

launch_runs impl_1
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Board-stable implementation failed."
    exit 1
}

open_run impl_1
report_utilization -file project/board_stable_utilization.rpt -pb project/board_stable_utilization.pb
report_timing_summary -delay_type min_max -report_unconstrained \
    -file project/board_stable_timing_summary.rpt
report_timing -delay_type min -max_paths 20 -nworst 2 \
    -file project/board_stable_hold_paths.rpt
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file project/board_stable_setup_paths.rpt
report_design_analysis -congestion -file project/board_stable_congestion.rpt
report_drc -file project/board_stable_drc.rpt

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]
puts "DSP48E1 cells: [llength $dsp_cells]"
if {[llength $dsp_cells] != 0} {
    puts "ERROR: This design must synthesize without DSP48 blocks."
    exit 1
}

set worst_setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set worst_hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $worst_setup_path] == 0 || [llength $worst_hold_path] == 0} {
    puts "ERROR: Missing timing path."
    exit 1
}

set worst_setup [get_property SLACK $worst_setup_path]
set worst_hold [get_property SLACK $worst_hold_path]
puts "Board-stable worst setup slack: $worst_setup ns"
puts "Board-stable worst hold slack: $worst_hold ns"

# 0.10 ns 是在当前板级约束和 50 MHz 频率下的保守门槛；若达不到，宁可不交付
# 该 bitstream，也不把“理论时序通过但实板启动不稳定”的文件当作提交版本。
if {$worst_setup < 0.10} {
    puts "ERROR: Setup margin below 0.10 ns."
    exit 1
}
if {$worst_hold < 0.10} {
    puts "ERROR: Hold margin below 0.10 ns."
    exit 1
}

close_project
exit 0
