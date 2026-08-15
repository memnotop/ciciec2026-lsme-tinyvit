# open project
open_project project/Loongson_Soc.xpr

add_files -quiet ../rtl/ip/lsme/lsme_udiv32.v
add_files -quiet ../rtl/ip/lsme/lsme_isqrt32.v
add_files -quiet ../rtl/ip/lsme/lsme_rmsnorm_core.v
update_compile_order -fileset sources_1

# generate Bitstream
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1

set impl_run [get_runs impl_1]
set impl_progress [get_property PROGRESS $impl_run]
set impl_status [get_property STATUS $impl_run]
puts "impl_1 progress: $impl_progress"
puts "impl_1 status: $impl_status"

set bit_files [glob -nocomplain project/Loongson_Soc.runs/impl_1/*.bit]
if {[llength $bit_files] == 0} {
    puts "ERROR: Bitstream file was not generated!"
    exit 1
}

puts "Generated bitstream files:"
foreach bit_file $bit_files {
    puts "  $bit_file"
}

close_project
exit 0
