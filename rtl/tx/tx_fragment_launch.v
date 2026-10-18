// Latch scheduler metadata/config at its start edge, then acquire one SN.
// PMEM read requests are accepted on the granted edge and return one cycle later.
`timescale 1 ns / 1 ps
module tx_fragment_launch (
  input wire clk,rst_sync,start,
  input wire [7:0] start_vl,
  input wire [3:0] start_head,
  input wire [13:0] app_length,fragment_offset,
  input wire [15:0] blocks,identification,
  input wire [2:0] block_count,
  input wire [15:0] vlid,udi,sport,dport,
  input wire [2:0] ifid_a,ifid_b,
  input wire [7:0] tos,ttl,
  input wire [31:0] src_ip,dst_ip,
  input wire checksum_enable,
  output wire busy,
  output wire done,error,
  output reg [7:0] current_vl,
  output reg [3:0] current_head,
  output wire last_fragment,
  output wire [13:0] next_offset,
  output wire snap_req,
  output wire [7:0] snap_vl,
  input wire [7:0] snap,
  input wire snap_ack,
  output wire pmem_req,
  output wire [12:0] pmem_addr,
  input wire pmem_grant,
  input wire [31:0] pmem_data,
  output wire out_valid,out_sof,out_eof,
  output wire [7:0] out_byte_a,out_byte_b,
  input wire out_ready
);
  localparam [1:0] IDLE=0,SNAPSHOT=1,LAUNCH=2,BUILD=3;
  reg [1:0] state;
  reg [13:0] len_q,offset_q;
  reg [15:0] blocks_q,id_q,vlid_q,udi_q,sport_q,dport_q;
  reg [2:0] count_q,ifid_a_q,ifid_b_q;
  reg [7:0] tos_q,ttl_q,sn_q;
  reg [31:0] src_q,dst_q;
  reg checksum_q,response_valid;
  wire builder_ready,builder_busy,builder_done,builder_error;
  wire [10:0] payload_length;
  assign busy=state!=IDLE;
  assign done=builder_done;
  assign error=builder_error;
  assign snap_req=start && state==IDLE && !rst_sync;
  assign snap_vl=state==IDLE ? start_vl : current_vl;
  tx_fragment_frame_builder u_fragment (
    .clk(clk),.rst_sync(rst_sync),.start(state==LAUNCH),.cancel(1'b0),.start_ready(builder_ready),
    .app_len(len_q),.blocks(blocks_q),.block_count(count_q),.fragment_offset(offset_q),
    .identification(id_q),.vlid(vlid_q),.udi(udi_q),.ifid_a(ifid_a_q),.ifid_b(ifid_b_q),
    .tos(tos_q),.ttl(ttl_q),.sequence_number(sn_q),.source_ip(src_q),.destination_ip(dst_q),
    .source_port(sport_q),.destination_port(dport_q),.udp_checksum_enable(checksum_q),
    .pmem_req_valid(pmem_req),.pmem_req_grant(pmem_grant),.pmem_req_addr(pmem_addr),
    .pmem_rsp_valid(response_valid),.pmem_rsp_data(pmem_data),
    .out_valid(out_valid),.out_ready(out_ready),.out_byte_a(out_byte_a),.out_byte_b(out_byte_b),
    .out_sof(out_sof),.out_eof(out_eof),.done(builder_done),.error(builder_error),.busy(builder_busy),
    .last_fragment(last_fragment),.next_fragment_offset(next_offset),.fragment_payload_len(payload_length)
  );
  always @(posedge clk) begin
    if(rst_sync) begin
      state<=IDLE;current_vl<=0;current_head<=0;len_q<=0;offset_q<=0;
      blocks_q<=0;id_q<=0;vlid_q<=0;udi_q<=0;sport_q<=0;dport_q<=0;
      count_q<=0;ifid_a_q<=0;ifid_b_q<=0;tos_q<=0;ttl_q<=0;sn_q<=0;
      src_q<=0;dst_q<=0;checksum_q<=0;response_valid<=0;
    end else begin
      response_valid<=pmem_req && pmem_grant;
      case(state)
        IDLE: if(start) begin
          current_vl<=start_vl;current_head<=start_head;
          len_q<=app_length;offset_q<=fragment_offset;blocks_q<=blocks;id_q<=identification;
          vlid_q<=vlid;udi_q<=udi;sport_q<=sport;dport_q<=dport;count_q<=block_count;
          ifid_a_q<=ifid_a;ifid_b_q<=ifid_b;tos_q<=tos;ttl_q<=ttl;src_q<=src_ip;dst_q<=dst_ip;
          checksum_q<=checksum_enable;state<=SNAPSHOT;
        end
        SNAPSHOT: if(snap_ack) begin sn_q<=snap;state<=LAUNCH;end
        LAUNCH: if(builder_ready) state<=BUILD;
        BUILD: if(builder_done || builder_error) state<=IDLE;
        default:state<=IDLE;
      endcase
    end
  end
endmodule
