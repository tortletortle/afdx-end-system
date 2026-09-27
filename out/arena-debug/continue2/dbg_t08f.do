vsim -voptargs=+acc tb_t08f_full_scoreboard
set n 0
when -label dbg {/tb_t08f_full_scoreboard/dut/rxc_rd_d == 1 && /tb_t08f_full_scoreboard/clk == 0} {
  global n
  incr n
  if {$n <= 4} {
    echo "t=[now] sel=[examine -hex /tb_t08f_full_scoreboard/dut/rxc_sel_d] h0=[examine -hex /tb_t08f_full_scoreboard/dut/rxq_host_w0] h1=[examine -hex /tb_t08f_full_scoreboard/dut/rxq_host_w1] out=[examine -hex /tb_t08f_full_scoreboard/dut/host_rdata] hash=[examine /tb_t08f_full_scoreboard/dut/hash_rd_d] pm=[examine /tb_t08f_full_scoreboard/dut/pmem_rd_d] desc=[examine /tb_t08f_full_scoreboard/dut/desc_rd_d] m0=[examine -hex {/tb_t08f_full_scoreboard/dut/u_rxcfg_h0/mem[0]}]"
  }
}
run 3 ms
quit -f
