# 在不进行布局布线前检查融合网表与实板基线的物理复用基础。
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set source_dcp [file join $script_dir project_rgb332_fused_attention_local Rgb332FusedAttentionLocal.runs synth_1 soc_top.dcp]
set reference_dcp [file join $script_dir project_rgb332_baseline_dvi Rgb332BaselineDvi.runs impl_1 soc_top_routed.dcp]
set pll_xci [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set constraints [file join $archive_root fpga constraints soc.xdc]
set report_file [file join $script_dir project_rgb332_fused_attention_local incremental_reuse_probe.rpt]

foreach required [list $source_dcp $reference_dcp $pll_xci $constraints] {
    if {![file exists $required]} {
        puts "ERROR: reuse-probe prerequisite is missing: $required"
        exit 1
    }
}

create_project -in_memory -part xc7a200tfbg676-1
add_files -quiet $source_dcp
read_ip -quiet $pll_xci
read_xdc $constraints
link_design -top soc_top -part xc7a200tfbg676-1
opt_design -directive Explore
read_checkpoint -incremental -directive TimingClosure $reference_dcp
report_incremental_reuse -file $report_file
puts "Local-fusion reuse probe: $report_file"
close_design
exit 0
