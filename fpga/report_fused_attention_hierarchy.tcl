# 检查融合 Attention 候选综合网表中的层级保持属性。
set script_dir [file dirname [file normalize [info script]]]
set dcp [file join $script_dir project_rgb332_fused_attention_shared Rgb332FusedAttentionShared.runs synth_1 soc_top.dcp]

if {![file exists $dcp]} {
    puts "ERROR: synthesis checkpoint is missing: $dcp"
    exit 1
}

open_checkpoint $dcp
foreach cell_name {u_lsme/u_core u_lsme/u_exec u_lsme/u_core/u_mopa} {
    set cells [get_cells -quiet $cell_name]
    if {[llength $cells] != 1} {
        puts "ERROR: expected one cell named $cell_name, got [llength $cells]"
        exit 1
    }
    puts "$cell_name KEEP_HIERARCHY=[get_property KEEP_HIERARCHY $cells]"
    puts "$cell_name descendant_cells=[llength [get_cells -hierarchical -quiet ${cell_name}/*]]"
}
close_design
exit 0
