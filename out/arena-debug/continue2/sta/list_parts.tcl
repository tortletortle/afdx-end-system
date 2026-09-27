# continue2: 列出本机 Quartus(Passkey) 实际安装的 Stratix IV 器件型号
set fh [open "out/arena-debug/continue2/sta/part_list.txt" w]
foreach f [get_family_list] { puts $fh "FAMILY: $f" }
foreach d [get_part_list -family "Stratix IV"] { puts $fh $d }
close $fh
puts "part list written"
