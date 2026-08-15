open_checkpoint project/Loongson_Soc.runs/impl_1/soc_top_routed.dcp

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]
puts "DSP48E1 cells: [llength $dsp_cells]"
foreach cell $dsp_cells {
    puts "  $cell"
}

report_utilization -hierarchical -hierarchical_depth 4 \
    -file project/hierarchical_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -file project/timing_summary.rpt
close_design
exit 0
