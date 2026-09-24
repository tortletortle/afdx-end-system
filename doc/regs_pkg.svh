// 由 tools/gen_regs.py 从 doc/regs.yaml 生成，请勿手改。
`define REG_WIDTH 32

localparam int ADDR_ID             = 16'h0000;   // ro
localparam int ADDR_REV            = 16'h0004;   // ro
localparam int ADDR_CTL            = 16'h0008;   // rw
localparam int ADDR_STATUS         = 16'h000C;   // ro
localparam int ADDR_ERR            = 16'h0010;   // w1c
localparam int ADDR_INT_ENABLE     = 16'h0014;   // rw
localparam int ADDR_INT_STATUS     = 16'h0018;   // w1c
localparam int ADDR_DROP_CNT       = 16'h001C;   // ro
localparam int ADDR_DROP_CNT_K     = 16'h0020;   // ro
localparam int ADDR_TB_CNT_US      = 16'h0050;   // ro
localparam int ADDR_TB_CNT_US_HI   = 16'h0054;   // ro
localparam int ADDR_CFG_SUM        = 16'h0058;   // ro
localparam int ADDR_CFG_ERR        = 16'h005C;   // ro
localparam int ADDR_SMAC_CFG       = 16'h0060;   // rw
localparam int ADDR_IP_CFG         = 16'h0064;   // rw
localparam int ADDR_TFTP_PEER_PORT = 16'h0068;   // ro
localparam int ADDR_SNMP_PEER_IP   = 16'h006C;   // ro
localparam int ADDR_UDP_CFG        = 16'h0070;   // rw
localparam int ADDR_TX_WR_BLK      = 16'h0074;   // ro
localparam int ADDR_HASH_SEED0     = 16'h0078;   // rw
localparam int ADDR_HASH_SEED1     = 16'h007C;   // rw
localparam int ADDR_HASH_IMAGE     = 16'h0080;   // rw
localparam int ADDR_DBG_CTRL       = 16'h00FC;   // rw
localparam int ADDR_STATS_BLOCK    = 16'h0100;   // ro

// 访问属性位图（host_if 译码用）：bit0=可写, bit1=可读, bit2=W1C
localparam bit [2:0] ACC_ID             = 3'b010;
localparam bit [2:0] ACC_REV            = 3'b010;
localparam bit [2:0] ACC_CTL            = 3'b011;
localparam bit [2:0] ACC_STATUS         = 3'b010;
localparam bit [2:0] ACC_ERR            = 3'b111;
localparam bit [2:0] ACC_INT_ENABLE     = 3'b011;
localparam bit [2:0] ACC_INT_STATUS     = 3'b111;
localparam bit [2:0] ACC_DROP_CNT       = 3'b010;
localparam bit [2:0] ACC_DROP_CNT_K     = 3'b010;
localparam bit [2:0] ACC_TB_CNT_US      = 3'b010;
localparam bit [2:0] ACC_TB_CNT_US_HI   = 3'b010;
localparam bit [2:0] ACC_CFG_SUM        = 3'b010;
localparam bit [2:0] ACC_CFG_ERR        = 3'b010;
localparam bit [2:0] ACC_SMAC_CFG       = 3'b011;
localparam bit [2:0] ACC_IP_CFG         = 3'b011;
localparam bit [2:0] ACC_TFTP_PEER_PORT = 3'b010;
localparam bit [2:0] ACC_SNMP_PEER_IP   = 3'b010;
localparam bit [2:0] ACC_UDP_CFG        = 3'b011;
localparam bit [2:0] ACC_TX_WR_BLK      = 3'b010;
localparam bit [2:0] ACC_HASH_SEED0     = 3'b011;
localparam bit [2:0] ACC_HASH_SEED1     = 3'b011;
localparam bit [2:0] ACC_HASH_IMAGE     = 3'b011;
localparam bit [2:0] ACC_DBG_CTRL       = 3'b011;
localparam bit [2:0] ACC_STATS_BLOCK    = 3'b010;

localparam logic [31:0] CTL_RESET = 32'h0000051C;
localparam logic [31:0] UDP_CFG_RESET = 32'h00000142;
