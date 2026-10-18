§8.8 过程式检查器（O-16）。不用 $error / FAIL 字样。
引脚：chk_mac A1/A3/A4/A12；chk_bag A5。
bind：A2/A6/A7/A8/A9/A10/A11；§12.3 手工档 afdx_cov_ic / afdx_cov_rm。
mac_bfm：T31/T32 注帧走 load_byte+inject。cover_hand.csv 由 T26 写出。
§12.1 顶层：tb/tb_afdx_top.sv（INIT 冒烟，不进 T00–T22 清单）。
