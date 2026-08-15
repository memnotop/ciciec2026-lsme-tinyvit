# 从已布线的强制增量实现检查点导出最差建立/保持路径。
# 该脚本只读取检查点并生成报告，不会修改实现结果。
open_checkpoint [file normalize [file join [file dirname [info script]] project_rmsnorm_force_incremental lsme_v2_rmsnorm_force_incremental_routed.dcp]]
report_timing -delay_type max -max_paths 1 -nworst 1 \
    -file /tmp/lsme_force_incremental_setup.rpt
report_timing -delay_type min -max_paths 1 -nworst 1 \
    -file /tmp/lsme_force_incremental_hold.rpt
close_design
exit
