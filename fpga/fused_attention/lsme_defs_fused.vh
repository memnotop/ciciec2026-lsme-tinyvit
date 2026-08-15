`ifndef LSME_DEFS_VH
`define LSME_DEFS_VH

// LACC 命令字段，对应自定义指令中的 command 位。
`define LSME_CMD_CTRL       3'd0
`define LSME_CMD_LDZ        3'd1
`define LSME_CMD_PSET       3'd2
`define LSME_CMD_ZERO       3'd3
`define LSME_CMD_SMOPA      3'd4
`define LSME_CMD_STZA       3'd5
`define LSME_CMD_EXEC       3'd6
`define LSME_CMD_WAIT       3'd7

// 描述符 operation，存放在 word0[7:0]。
`define LSME_OP_GEMM        8'd1
`define LSME_OP_SOFTMAX     8'd2
`define LSME_OP_VECTOR_ADD  8'd3
`define LSME_OP_FUSED_ATTENTION 8'd5

// 描述符 flags，存放在 word0[31:8]。下面的数值是该 24 位字段内的位号。
`define LSME_FLAG_TRANS_B           0
`define LSME_FLAG_OUTPUT_INT8       1
`define LSME_FLAG_BIAS              2
`define LSME_FLAG_RELU              3
`define LSME_FLAG_ACCUMULATE        4
`define LSME_FLAG_HEAD4             5
`define LSME_FLAG_PER_CHANNEL_SHIFT 6

// 通过状态寄存器报告的调度模式。
`define LSME_MODE_K_SPLIT    2'd0
`define LSME_MODE_TILE8      2'd1
`define LSME_MODE_HEAD4      2'd2
`define LSME_MODE_MACRO8     2'd3

// 描述符 word15 的 V2 签名和执行模式。
// word15[31:16] 必须等于 16'h5632 才会被识别为 V2 描述符；
// word15[15:8] 当前保留为 0，word15[7:0] 是下面的 mode。
`define LSME_V2_AUX_MAGIC    16'h5632
`define LSME_V2_MODE_AUTO    8'd0  // 自动选择；当前实现会进入 V2 cached GEMM
`define LSME_V2_MODE_CACHED  8'd1  // 明确要求进入 V2 cached GEMM
`define LSME_V2_MODE_STREAM  8'd2  // 强制使用兼容的 V1 4×4 流式 GEMM

`endif
