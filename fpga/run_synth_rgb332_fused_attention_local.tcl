# 仅替换 LSME 执行器的融合 Attention 综合流。
#
# 不再引入带 keep_hierarchy 的 lsme_top/lsme_core 副本，也不改变原有 Softmax。
# 这样除 u_exec 与新增融合子核外，区域赛已验证的 V2 LSME 网表保持不变，
# 后续增量实现能够保留 CPU、AXI 和 MOPA 的物理结构。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set fused_dir [file join $script_dir fused_attention]
set project_name Rgb332FusedAttentionLocal
set project_path [file join $script_dir project_rgb332_fused_attention_local]
set part xc7a200tfbg676-1
set archive_exec [file join $archive_root rtl ip lsme lsme_exec_engine.v]
set archive_pll [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set archive_xdc [file join $archive_root fpga constraints soc.xdc]
set fused_exec [file join $fused_dir lsme_exec_engine.v]
set fused_core [file join $fused_dir lsme_fused_attention_core.v]
set fused_softmax_sram [file join $fused_dir lsme_softmax_score_sram.v]

foreach required [list $archive_exec $archive_pll $archive_xdc $fused_exec \
                       $fused_core $fused_softmax_sram] {
    if {![file exists $required]} {
        puts "ERROR: required local-fusion source is missing: $required"
        exit 1
    }
}

file delete -force $project_path
create_project -force $project_name $project_path -part $part
set_param general.maxThreads 8

# 基线文件集与已启动成功的 RGB332-DVI 工程相同，唯一替换为 u_exec。
add_files -scan_for_includes [file join $archive_root rtl]
set old_exec [get_files -quiet $archive_exec]
if {[llength $old_exec] != 1} {
    puts "ERROR: archived execution engine was not added exactly once"
    exit 1
}
remove_files $old_exec
add_files -norecurse -scan_for_includes $fused_exec
add_files -norecurse -scan_for_includes $fused_core
add_files -norecurse -scan_for_includes $fused_softmax_sram
set_property include_dirs [list $fused_dir [file join $archive_root rtl ip lsme]] \
    [current_fileset]
add_files -norecurse -scan_for_includes $archive_pll
add_files -fileset constrs_1 -quiet $archive_xdc
set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1
upgrade_ip -quiet [get_ips]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: local-fusion synthesis failed"
    exit 1
}

set dcp_file [file join $project_path ${project_name}.runs synth_1 soc_top.dcp]
if {![file exists $dcp_file]} {
    puts "ERROR: local-fusion synthesis checkpoint was not generated"
    exit 1
}
puts "Local-fusion synthesis checkpoint: $dcp_file"
close_project
exit 0
