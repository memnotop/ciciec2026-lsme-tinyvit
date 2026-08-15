# 导出区域赛基线中 MOPA 累加阵列的实际放置范围，为融合版本 Pblock 提供依据。

set script_dir [file dirname [file normalize [info script]]]
set reference_dcp [file join $script_dir project_rgb332_baseline_dvi Rgb332BaselineDvi.runs impl_1 soc_top_routed.dcp]
set output_rpt [file join $script_dir baseline_mopa_placement.rpt]
if {![file exists $reference_dcp]} {
    puts "ERROR: baseline checkpoint is missing: $reference_dcp"
    exit 1
}
open_checkpoint $reference_dcp
set fh [open $output_rpt w]
puts $fh "# cell loc"
set cells [get_cells -hierarchical -filter {NAME =~ u_lsme/u_core/u_mopa/*}]
set counted 0
foreach cell $cells {
    set loc [get_property LOC $cell]
    if {$loc ne ""} {
        puts $fh "[get_property NAME $cell] $loc"
        incr counted
    }
}
puts $fh "# placed_cells $counted"
puts $fh "# core cell loc"
set core_cells [get_cells -hierarchical -filter {NAME =~ u_lsme/u_core/*}]
set core_counted 0
foreach cell $core_cells {
    set loc [get_property LOC $cell]
    if {$loc ne ""} {
        puts $fh "[get_property NAME $cell] $loc"
        incr core_counted
    }
}
puts $fh "# core_placed_cells $core_counted"
close $fh
puts "Baseline MOPA placement report: $output_rpt"
close_design
exit 0
