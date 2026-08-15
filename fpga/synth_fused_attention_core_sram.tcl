# 快速检查融合核的 score SRAM 是否按存储器而非宽寄存器综合。
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set out_dir [file join $script_dir build fused_attention_core_sram_synth]
file mkdir $out_dir

read_verilog -sv [file join $root_dir rtl ip lsme lsme_softmax_core.v] \
    [file join $script_dir fused_attention lsme_fused_attention_core.v]
synth_design -top lsme_fused_attention_core -part xc7a200tfbg676-1
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $out_dir utilization.rpt]
write_checkpoint -force [file join $out_dir lsme_fused_attention_core_sram.dcp]
exit 0
