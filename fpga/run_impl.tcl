# bit.tcl
open_project project/Loongson_Soc.xpr

# 兼容从旧版本工程直接升级，避免为了三个新 RTL 文件清空已有工程。
add_files -quiet ../rtl/ip/lsme/lsme_udiv32.v
add_files -quiet ../rtl/ip/lsme/lsme_isqrt32.v
add_files -quiet ../rtl/ip/lsme/lsme_rmsnorm_core.v
update_compile_order -fileset sources_1

# Add myCPU
# add_files -scan_for_includes mysrc

# Add xilinx_ip in myCPU
# add_files -quiet [glob -nocomplain mysrc/xilinx_ip/*/*.xci]
# add_files -quiet [glob -nocomplain mysrc/xilinx_ip/*/*.xcix]

# Upgrade IPs
upgrade_ip -quiet [get_ips]

# run_impl
reset_run synth_1
# Use a timing-oriented but reproducible implementation recipe.  Architectural
# registers now cut the SRAM pin path; physical optimisation is used only for
# replication/rewiring, without timing exceptions or hand pblocks.
catch {set_property strategy Performance_Explore [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
       [get_runs impl_1]}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore \
       [get_runs impl_1]}
launch_runs impl_1
wait_on_run impl_1

# check impl status
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# open_run impl_1
open_run impl_1
report_utilization -file project/dsp_utilization.rpt -pb project/dsp_utilization.pb
report_utilization -hierarchical -hierarchical_depth 4 \
    -file project/hierarchical_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -file project/timing_summary.rpt
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file project/critical_paths.rpt
report_design_analysis -congestion -file project/congestion.rpt
report_drc -file project/drc.rpt

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]
puts "DSP48E1 cells: [llength $dsp_cells]"
if {[llength $dsp_cells] != 0} {
    foreach cell $dsp_cells { puts "  $cell" }
    puts "ERROR: This design must synthesize without DSP48 blocks."
    exit 1
}

set worst_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_path] == 0} {
    puts "ERROR: No setup timing path was reported."
    exit 1
}
set worst_slack [get_property SLACK $worst_path]
puts "Worst setup slack: $worst_slack ns"
if {$worst_slack < 0.0} {
    puts "ERROR: Setup timing is not met."
    exit 1
}

# report_timing_summary -delay_type min_max -report_unconstrained \
#     -file lab/lab1.runs/impl_1/timing_summary.rpt
 
close_project
exit 0
