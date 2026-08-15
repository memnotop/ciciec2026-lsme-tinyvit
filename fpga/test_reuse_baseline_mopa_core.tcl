# 验证在融合 Attention 的综合网表中以 DCP 形式重新植入 u_core 是否可行。
# 只执行网表拼装与 checkpoint 写出，不进行布局布线。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set source_dcp [file join $script_dir project_rgb332_fused_attention_shared Rgb332FusedAttentionShared.runs synth_1 soc_top.dcp]
set core_dcp [file join $script_dir baseline_lsme_core_routed.dcp]
set pll_xci [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set constraints [file join $archive_root fpga constraints soc.xdc]
set output_dcp [file join $script_dir fused_attention_with_reused_core_test.dcp]
foreach required [list $source_dcp $core_dcp $pll_xci $constraints] {
    if {![file exists $required]} {
        puts "ERROR: required reuse input is missing: $required"
        exit 1
    }
}
create_project -in_memory -part xc7a200tfbg676-1
add_files -quiet $source_dcp
read_ip -quiet $pll_xci
read_xdc $constraints
link_design -top soc_top -part xc7a200tfbg676-1
set target_core [get_cells -quiet u_lsme/u_core]
if {[llength $target_core] != 1} {
    puts "ERROR: fused netlist does not contain exactly one u_lsme/u_core"
    exit 1
}
update_design -cells $target_core -black_box
read_checkpoint -cell u_lsme/u_core $core_dcp
write_checkpoint -force $output_dcp
puts "MOPA core reuse test passed: $output_dcp"
close_design
exit 0
