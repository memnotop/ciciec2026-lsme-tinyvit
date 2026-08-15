open_project project/Loongson_Soc.xpr
# 兼容已有工程：新增自主 IP 文件无需删除并重建整个 Vivado 工程。
add_files -quiet ../rtl/ip/lsme/lsme_udiv32.v
add_files -quiet ../rtl/ip/lsme/lsme_isqrt32.v
add_files -quiet ../rtl/ip/lsme/lsme_rmsnorm_core.v
update_compile_order -fileset sources_1
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
