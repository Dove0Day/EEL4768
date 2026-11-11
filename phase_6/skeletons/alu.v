`default_nettype none

// The arithmetic logic unit (ALU) is responsible for performing the core
// calculations of the processor. It takes two 32-bit operands and outputs
// a 32 bit result based on the selection operation - addition, comparison,
// shift, or logical operation. Every RV32I operation is purely
// combinational. In phase 6 the ALU also performs the RV32M multiply and
// divide instructions, which may be combinational or take several cycles
// (see `documentation/phase_6.pdf`).
module alu (
    // Global clock and synchronous active-high reset (used by an iterative
    // multiplier or divider).
    input  wire        i_clk,
    input  wire        i_rst,
    // Major operation selection.
    // 3'b000: addition/subtraction if `i_sub` asserted
    // 3'b001: shift left logical
    // 3'b010: set less than
    // 3'b011: set less than unsigned
    // 3'b100: exclusive or
    // 3'b101: shift right logical/arithmetic if `i_arith` asserted
    // 3'b110: or
    // 3'b111: and
    // When `i_mext` is asserted, this is the M instruction's funct3 instead:
    // 3'b000: mul    - low 32 bits of op1 * op2
    // 3'b001: mulh   - high 32 bits of signed op1 * signed op2
    // 3'b010: mulhsu - high 32 bits of signed op1 * unsigned op2
    // 3'b011: mulhu  - high 32 bits of unsigned op1 * unsigned op2
    // 3'b100: div    - signed op1 / op2, rounded toward zero
    // 3'b101: divu   - unsigned op1 / op2
    // 3'b110: rem    - signed remainder, same sign as op1
    // 3'b111: remu   - unsigned remainder
    input  wire [ 2:0] i_opsel,
    // When asserted, addition operations should subtract instead.
    // This is only used for `i_opsel == 3'b000` (addition/subtraction).
    input  wire        i_sub,
    // When asserted, comparison operations should be treated as unsigned.
    // This is only used for branch comparisons, as the set less than unsigned
    // mode is already specified by `i_opsel`. For branch operations, the ALU
    // result is not used, only the comparison results.
    input  wire        i_unsigned,
    // When asserted, right shifts should be treated as arithmetic instead of
    // logical. This is only used for `i_opsel == 3'b101` (shift right).
    input  wire        i_arith,
    // Asserted while an RV32M instruction is in the execute stage.
    input  wire        i_mext,
    // Asserted when the instruction in the execute stage moves on at the next
    // rising edge. A finished M result is held until then.
    input  wire        i_advance,
    // First 32-bit input operand.
    input  wire [31:0] i_op1,
    // Second 32-bit input operand.
    input  wire [31:0] i_op2,
    // 32-bit output result. Any carry out (from addition) should be ignored.
    output wire [31:0] o_result,
    // Equality result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_eq,
    // Set less than result. This is used downstream to determine if a
    // branch should be taken.
    output wire        o_slt,
    // Asserted while an M operation is still running; the instruction must
    // stay in the execute stage until it drops.
    output wire        o_busy
);

    // Write your code here.
    // Your implementation goes under here
    // ------------------------------------

    // Prepare operands for addition or subtraction
    // Subtraction = invert op2 and set initial carry-in to 1:
    // A - B = A + ~B + 1.
    wire [31:0] add_b, add_p, add_g, add_result;
    wire [7:0] group_p, group_g, group_c;
    assign add_b = i_op2 ^ {32{i_sub}};
    assign add_p = i_op1 ^ add_b;
    assign add_g = i_op1 & add_b;

    // Carry-lookahead adder
    assign group_p[0] = add_p[0] & add_p[1] & add_p[2] & add_p[3];
    assign group_g[0] = (add_g[3]) | (add_p[3] & add_g[2]) | (add_p[3] & add_p[2] & add_g[1]) | (add_p[3] & add_p[2] & add_p[1] & add_g[0]);
    assign group_p[1] = add_p[4] & add_p[5] & add_p[6] & add_p[7];
    assign group_g[1] = (add_g[7]) | (add_p[7] & add_g[6]) | (add_p[7] & add_p[6] & add_g[5]) | (add_p[7] & add_p[6] & add_p[5] & add_g[4]);
    assign group_p[2] = add_p[8] & add_p[9] & add_p[10] & add_p[11];
    assign group_g[2] = (add_g[11]) | (add_p[11] & add_g[10]) | (add_p[11] & add_p[10] & add_g[9]) | (add_p[11] & add_p[10] & add_p[9] & add_g[8]);
    assign group_p[3] = add_p[12] & add_p[13] & add_p[14] & add_p[15];
    assign group_g[3] = (add_g[15]) | (add_p[15] & add_g[14]) | (add_p[15] & add_p[14] & add_g[13]) | (add_p[15] & add_p[14] & add_p[13] & add_g[12]);
    assign group_p[4] = add_p[16] & add_p[17] & add_p[18] & add_p[19];
    assign group_g[4] = (add_g[19]) | (add_p[19] & add_g[18]) | (add_p[19] & add_p[18] & add_g[17]) | (add_p[19] & add_p[18] & add_p[17] & add_g[16]);
    assign group_p[5] = add_p[20] & add_p[21] & add_p[22] & add_p[23];
    assign group_g[5] = (add_g[23]) | (add_p[23] & add_g[22]) | (add_p[23] & add_p[22] & add_g[21]) | (add_p[23] & add_p[22] & add_p[21] & add_g[20]);
    assign group_p[6] = add_p[24] & add_p[25] & add_p[26] & add_p[27];
    assign group_g[6] = (add_g[27]) | (add_p[27] & add_g[26]) | (add_p[27] & add_p[26] & add_g[25]) | (add_p[27] & add_p[26] & add_p[25] & add_g[24]);
    assign group_p[7] = add_p[28] & add_p[29] & add_p[30] & add_p[31];
    assign group_g[7] = (add_g[31]) | (add_p[31] & add_g[30]) | (add_p[31] & add_p[30] & add_g[29]) | (add_p[31] & add_p[30] & add_p[29] & add_g[28]);
    
    // Within each 4 bit group, calculate the carries needed for sum bits
    // The carry into the next group comes from group_c
    assign group_c[0] = i_sub;
    assign group_c[1] = (group_g[0]) | (group_p[0] & group_c[0]);
    assign group_c[2] = (group_g[1]) | (group_p[1] & group_g[0]) | (group_p[1] & group_p[0] & group_c[0]);
    assign group_c[3] = (group_g[2]) | (group_p[2] & group_g[1]) | (group_p[2] & group_p[1] & group_g[0]) | (group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[4] = (group_g[3]) | (group_p[3] & group_g[2]) | (group_p[3] & group_p[2] & group_g[1]) | (group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[5] = (group_g[4]) | (group_p[4] & group_g[3]) | (group_p[4] & group_p[3] & group_g[2]) | (group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[6] = (group_g[5]) | (group_p[5] & group_g[4]) | (group_p[5] & group_p[4] & group_g[3]) | (group_p[5] & group_p[4] & group_p[3] & group_g[2]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[7] = (group_g[6]) | (group_p[6] & group_g[5]) | (group_p[6] & group_p[5] & group_g[4]) | (group_p[6] & group_p[5] & group_p[4] & group_g[3]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_g[2]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    wire c1_0, c2_0, c3_0;

    // Carry look-ahead within each 4-bit block
    // group_c supplies the carry-in for each block
    assign c1_0 = add_g[0] | (add_p[0] & group_c[0]);
    assign c2_0 = add_g[1] | (add_p[1] & add_g[0]) | (add_p[1] & add_p[0] & group_c[0]);
    assign c3_0 = add_g[2] | (add_p[2] & add_g[1]) | (add_p[2] & add_p[1] & add_g[0]) | (add_p[2] & add_p[1] & add_p[0] & group_c[0]);
    
    // Sum bit = propagate bit XOR carry-in
    assign add_result[0] = add_p[0] ^ group_c[0];
    assign add_result[1] = add_p[1] ^ c1_0;
    assign add_result[2] = add_p[2] ^ c2_0;
    assign add_result[3] = add_p[3] ^ c3_0;

    // Carry look-ahead and sum bits for the remaining 4-bit blocks
    wire c1_1, c2_1, c3_1;
    assign c1_1 = add_g[4] | (add_p[4] & group_c[1]);
    assign c2_1 = add_g[5] | (add_p[5] & add_g[4]) | (add_p[5] & add_p[4] & group_c[1]);
    assign c3_1 = add_g[6] | (add_p[6] & add_g[5]) | (add_p[6] & add_p[5] & add_g[4]) | (add_p[6] & add_p[5] & add_p[4] & group_c[1]);
    assign add_result[4] = add_p[4] ^ group_c[1];
    assign add_result[5] = add_p[5] ^ c1_1;
    assign add_result[6] = add_p[6] ^ c2_1;
    assign add_result[7] = add_p[7] ^ c3_1;

    wire c1_2, c2_2, c3_2;
    assign c1_2 = add_g[8] | (add_p[8] & group_c[2]);
    assign c2_2 = add_g[9] | (add_p[9] & add_g[8]) | (add_p[9] & add_p[8] & group_c[2]);
    assign c3_2 = add_g[10] | (add_p[10] & add_g[9]) | (add_p[10] & add_p[9] & add_g[8]) | (add_p[10] & add_p[9] & add_p[8] & group_c[2]);
    assign add_result[8] = add_p[8] ^ group_c[2];
    assign add_result[9] = add_p[9] ^ c1_2;
    assign add_result[10] = add_p[10] ^ c2_2;
    assign add_result[11] = add_p[11] ^ c3_2;

    wire c1_3, c2_3, c3_3;
    assign c1_3 = add_g[12] | (add_p[12] & group_c[3]);
    assign c2_3 = add_g[13] | (add_p[13] & add_g[12]) | (add_p[13] & add_p[12] & group_c[3]);
    assign c3_3 = add_g[14] | (add_p[14] & add_g[13]) | (add_p[14] & add_p[13] & add_g[12]) | (add_p[14] & add_p[13] & add_p[12] & group_c[3]);
    assign add_result[12] = add_p[12] ^ group_c[3];
    assign add_result[13] = add_p[13] ^ c1_3;
    assign add_result[14] = add_p[14] ^ c2_3;
    assign add_result[15] = add_p[15] ^ c3_3;

    wire c1_4, c2_4, c3_4;
    assign c1_4 = add_g[16] | (add_p[16] & group_c[4]);
    assign c2_4 = add_g[17] | (add_p[17] & add_g[16]) | (add_p[17] & add_p[16] & group_c[4]);
    assign c3_4 = add_g[18] | (add_p[18] & add_g[17]) | (add_p[18] & add_p[17] & add_g[16]) | (add_p[18] & add_p[17] & add_p[16] & group_c[4]);
    assign add_result[16] = add_p[16] ^ group_c[4];
    assign add_result[17] = add_p[17] ^ c1_4;
    assign add_result[18] = add_p[18] ^ c2_4;
    assign add_result[19] = add_p[19] ^ c3_4;

    wire c1_5, c2_5, c3_5;
    assign c1_5 = add_g[20] | (add_p[20] & group_c[5]);
    assign c2_5 = add_g[21] | (add_p[21] & add_g[20]) | (add_p[21] & add_p[20] & group_c[5]);
    assign c3_5 = add_g[22] | (add_p[22] & add_g[21]) | (add_p[22] & add_p[21] & add_g[20]) | (add_p[22] & add_p[21] & add_p[20] & group_c[5]);
    assign add_result[20] = add_p[20] ^ group_c[5];
    assign add_result[21] = add_p[21] ^ c1_5;
    assign add_result[22] = add_p[22] ^ c2_5;
    assign add_result[23] = add_p[23] ^ c3_5;

    wire c1_6, c2_6, c3_6;
    assign c1_6 = add_g[24] | (add_p[24] & group_c[6]);
    assign c2_6 = add_g[25] | (add_p[25] & add_g[24]) | (add_p[25] & add_p[24] & group_c[6]);
    assign c3_6 = add_g[26] | (add_p[26] & add_g[25]) | (add_p[26] & add_p[25] & add_g[24]) | (add_p[26] & add_p[25] & add_p[24] & group_c[6]);
    assign add_result[24] = add_p[24] ^ group_c[6];
    assign add_result[25] = add_p[25] ^ c1_6;
    assign add_result[26] = add_p[26] ^ c2_6;
    assign add_result[27] = add_p[27] ^ c3_6;

    wire c1_7, c2_7, c3_7;
    assign c1_7 = add_g[28] | (add_p[28] & group_c[7]);
    assign c2_7 = add_g[29] | (add_p[29] & add_g[28]) | (add_p[29] & add_p[28] & group_c[7]);
    assign c3_7 = add_g[30] | (add_p[30] & add_g[29]) | (add_p[30] & add_p[29] & add_g[28]) | (add_p[30] & add_p[29] & add_p[28] & group_c[7]);
    assign add_result[28] = add_p[28] ^ group_c[7];
    assign add_result[29] = add_p[29] ^ c1_7;
    assign add_result[30] = add_p[30] ^ c2_7;
    assign add_result[31] = add_p[31] ^ c3_7;

    // Left barrel shifter
    // each stage shifts by a fixed amount
    wire [31:0] sll_1, sll_2, sll_4, sll_8, sll_16;
    assign sll_1=i_op2[0]?{i_op1[30:0],1'b0}:i_op1;
    assign sll_2=i_op2[1]?{sll_1[29:0],2'b0}:sll_1;
    assign sll_4=i_op2[2]?{sll_2[27:0],4'b0}:sll_2;
    assign sll_8=i_op2[3]?{sll_4[23:0],8'b0}:sll_4;
    assign sll_16=i_op2[4]?{sll_8[15:0],16'b0}:sll_8;

    // Right barrel shifter
    // When i_arith is set, each stage replicates the current sign bit; otherwise, 0s are shifted in
    wire [31:0] sr_1, sr_2, sr_4, sr_8, sr_16;
    assign sr_1=i_op2[0]?{{1{i_arith&i_op1[31]}},i_op1[31:1]}:i_op1;
    assign sr_2=i_op2[1]?{{2{i_arith&sr_1[31]}},sr_1[31:2]}:sr_1;
    assign sr_4=i_op2[2]?{{4{i_arith&sr_2[31]}},sr_2[31:4]}:sr_2;
    assign sr_8=i_op2[3]?{{8{i_arith&sr_4[31]}},sr_4[31:8]}:sr_4;
    assign sr_16=i_op2[4]?{{16{i_arith&sr_8[31]}},sr_8[31:16]}:sr_8;

    // SCan from the most-significant bit down
    // eq_above[i] is true when all bits more significant than i match.
    // First differing bit determines unsigned less-than
    wire [31:0] eq_above, lt_term; wire unsigned_lt, signed_lt;
    assign eq_above[31]=1'b1;
    assign eq_above[30] = eq_above[31] & ~(i_op1[31] ^ i_op2[31]);
    assign eq_above[29] = eq_above[30] & ~(i_op1[30] ^ i_op2[30]);
    assign eq_above[28] = eq_above[29] & ~(i_op1[29] ^ i_op2[29]);
    assign eq_above[27] = eq_above[28] & ~(i_op1[28] ^ i_op2[28]);
    assign eq_above[26] = eq_above[27] & ~(i_op1[27] ^ i_op2[27]);
    assign eq_above[25] = eq_above[26] & ~(i_op1[26] ^ i_op2[26]);
    assign eq_above[24] = eq_above[25] & ~(i_op1[25] ^ i_op2[25]);
    assign eq_above[23] = eq_above[24] & ~(i_op1[24] ^ i_op2[24]);
    assign eq_above[22] = eq_above[23] & ~(i_op1[23] ^ i_op2[23]);
    assign eq_above[21] = eq_above[22] & ~(i_op1[22] ^ i_op2[22]);
    assign eq_above[20] = eq_above[21] & ~(i_op1[21] ^ i_op2[21]);
    assign eq_above[19] = eq_above[20] & ~(i_op1[20] ^ i_op2[20]);
    assign eq_above[18] = eq_above[19] & ~(i_op1[19] ^ i_op2[19]);
    assign eq_above[17] = eq_above[18] & ~(i_op1[18] ^ i_op2[18]);
    assign eq_above[16] = eq_above[17] & ~(i_op1[17] ^ i_op2[17]);
    assign eq_above[15] = eq_above[16] & ~(i_op1[16] ^ i_op2[16]);
    assign eq_above[14] = eq_above[15] & ~(i_op1[15] ^ i_op2[15]);
    assign eq_above[13] = eq_above[14] & ~(i_op1[14] ^ i_op2[14]);
    assign eq_above[12] = eq_above[13] & ~(i_op1[13] ^ i_op2[13]);
    assign eq_above[11] = eq_above[12] & ~(i_op1[12] ^ i_op2[12]);
    assign eq_above[10] = eq_above[11] & ~(i_op1[11] ^ i_op2[11]);
    assign eq_above[9] = eq_above[10] & ~(i_op1[10] ^ i_op2[10]);
    assign eq_above[8] = eq_above[9] & ~(i_op1[9] ^ i_op2[9]);
    assign eq_above[7] = eq_above[8] & ~(i_op1[8] ^ i_op2[8]);
    assign eq_above[6] = eq_above[7] & ~(i_op1[7] ^ i_op2[7]);
    assign eq_above[5] = eq_above[6] & ~(i_op1[6] ^ i_op2[6]);
    assign eq_above[4] = eq_above[5] & ~(i_op1[5] ^ i_op2[5]);
    assign eq_above[3] = eq_above[4] & ~(i_op1[4] ^ i_op2[4]);
    assign eq_above[2] = eq_above[3] & ~(i_op1[3] ^ i_op2[3]);
    assign eq_above[1] = eq_above[2] & ~(i_op1[2] ^ i_op2[2]);
    assign eq_above[0] = eq_above[1] & ~(i_op1[1] ^ i_op2[1]);

    // Less-than term is active if
    // (1) all higher bits match
    // (2)this bit is 0 in op1 and 1 in op2
    assign lt_term = eq_above & ~i_op1 & i_op2;
    assign unsigned_lt = |lt_term;

    // FDiffering sign bits decide the result
    assign signed_lt = (i_op1[31] ^ i_op2[31]) ? i_op1[31] : unsigned_lt;
    assign o_eq = ~|(i_op1 ^ i_op2);
    assign o_slt = i_unsigned ? unsigned_lt : signed_lt;
    wire [31:0] slt_result={31'b0,signed_lt};
    wire [31:0] sltu_result={31'b0,unsigned_lt};
    
    // Select the result for the base RV32I ALU operations
    wire [31:0] rv32i_result = (i_opsel==3'b000)?add_result:(i_opsel==3'b001)?sll_16:(i_opsel==3'b010)?slt_result:(i_opsel==3'b011)?sltu_result:(i_opsel==3'b100)?(i_op1^i_op2):(i_opsel==3'b101)?sr_16:(i_opsel==3'b110)?(i_op1|i_op2):(i_op1&i_op2);

    // Phase 6
    // Multi-cycle multiply/divide state machine.
    // The operation and operands are captured when a request starts so
    // they remain stable while the pipeline is stalled.
    localparam [1:0] S_IDLE=2'd0, S_BUSY=2'd1, S_DONE=2'd2;
    reg [1:0] state; reg [4:0] step_cnt; reg [2:0] m_opsel; reg m_is_div;
    reg m_prod_neg, m_quot_neg, m_rem_neg, m_div_zero, m_div_overflow;
    reg [31:0] original_dividend, multiplier, dividend_reg, divisor_reg, quot_reg;
    reg [63:0] multiplicand, prod_reg; reg [32:0] rem_reg; reg [31:0] mext_result;

    // Decode whether the requested operation is a divide and which operands should be interpreted as signed
    // Sign flags are also used to convert operands to magnitudes before iterative operation begins
    wire start_is_div=i_opsel[2];
    wire start_op1_signed=start_is_div?~i_opsel[0]:((i_opsel==3'b001)||(i_opsel==3'b010));
    wire start_op2_signed=start_is_div?~i_opsel[0]:(i_opsel==3'b001);
    wire start_op1_neg=start_op1_signed&i_op1[31];
    wire start_op2_neg=start_op2_signed&i_op2[31];

    // Manual two's-complement magnitude conversion, no signal + or - operators
    wire [31:0] op1_inv;
    wire [31:0] op2_inv;
    wire [31:0] op1_twos;
    wire [31:0] op2_twos;
    assign op1_inv = ~i_op1;
    assign op2_inv = ~i_op2;
    wire [32:0] op1_nc,op2_nc; assign op1_nc[0]=1'b1; assign op2_nc[0]=1'b1;

    genvar n; generate for(n=0;n<32;n=n+1) begin: MAG_ADD
        assign op1_twos[n]=op1_inv[n]^op1_nc[n]; assign op1_nc[n+1]=op1_inv[n]&op1_nc[n];
        assign op2_twos[n]=op2_inv[n]^op2_nc[n]; assign op2_nc[n+1]=op2_inv[n]&op2_nc[n];
    end endgenerate
    wire [31:0] op1_mag=start_op1_neg?op1_twos:i_op1;
    wire [31:0] op2_mag=start_op2_neg?op2_twos:i_op2;

    // Shift-and-add multiplier datapath and final-step look-ahead
    wire [63:0] product_add; wire [64:0] product_c; assign product_c[0]=1'b0;
    generate for(n=0;n<64;n=n+1) begin: PRODUCT_ADD
        assign product_add[n]=prod_reg[n]^multiplicand[n]^product_c[n];
        assign product_c[n+1]=(prod_reg[n]&multiplicand[n])|(prod_reg[n]&product_c[n])|(multiplicand[n]&product_c[n]);
    end endgenerate
    wire [63:0] product_step=multiplier[0]?product_add:prod_reg;

    // Negate the completed product when exactly one signed operand was negative
    wire [63:0] product_inv;
    wire [63:0] product_twos;
    wire [64:0] product_nc;
    assign product_inv = ~product_step;
    assign product_nc[0] = 1'b1;
    generate for(n=0;n<64;n=n+1) begin: PRODUCT_NEG
        assign product_twos[n]=product_inv[n]^product_nc[n]; assign product_nc[n+1]=product_inv[n]&product_nc[n];
    end endgenerate
    wire [63:0] corrected_product=m_prod_neg?product_twos:product_step;

    // Restoring divider
    // The subtraction carry-out implements the unsigned comparison, and the full 33-bit remainder is retained
    wire [32:0] rem_shift={rem_reg[31:0],dividend_reg[31]};

    // Invert the complete 33-bit zero-extended divisor for subtraction
    wire [32:0] div_b={1'b1,~divisor_reg}; wire [32:0] rem_sub; wire [33:0] rem_c; assign rem_c[0]=1'b1;
    generate for(n=0;n<33;n=n+1) begin: REM_SUB
        assign rem_sub[n]=rem_shift[n]^div_b[n]^rem_c[n];
        assign rem_c[n+1]=(rem_shift[n]&div_b[n])|(rem_shift[n]&rem_c[n])|(div_b[n]&rem_c[n]);
    end endgenerate

    wire rem_ge=rem_c[33]; wire [32:0] rem_step=rem_ge?rem_sub:rem_shift;

    // Append the comparison result to the quotient: 1 if subtraction succeeded
    wire [31:0] quot_step={quot_reg[30:0],rem_ge};

    // Convert quotient and remainder back to signed results when needed
    wire [31:0] quot_inv;
    wire [31:0] rem_inv;
    wire [31:0] quot_twos;
    wire [31:0] rem_twos;
    assign quot_inv = ~quot_step;
    assign rem_inv = ~rem_step[31:0];
    wire [32:0] quot_nc,rem_nc; assign quot_nc[0]=1'b1; assign rem_nc[0]=1'b1;
    generate for(n=0;n<32;n=n+1) begin: DIV_NEG
        assign quot_twos[n]=quot_inv[n]^quot_nc[n]; assign quot_nc[n+1]=quot_inv[n]&quot_nc[n];
        assign rem_twos[n]=rem_inv[n]^rem_nc[n]; assign rem_nc[n+1]=rem_inv[n]&rem_nc[n];
    end endgenerate
    wire [31:0] corrected_quot=m_quot_neg?quot_twos:quot_step;
    wire [31:0] corrected_rem=m_rem_neg?rem_twos:rem_step[31:0];
    wire [4:0] next_step={step_cnt[4]^(&step_cnt[3:0]),step_cnt[3]^(&step_cnt[2:0]),step_cnt[2]^(&step_cnt[1:0]),step_cnt[1]^step_cnt[0],~step_cnt[0]};

    always @(posedge i_clk) begin
        if(i_rst) begin
            // Reset the state machine, control flags, operands, and datapath
            state<=S_IDLE; step_cnt<=5'd0; m_opsel<=3'd0; m_is_div<=1'b0;
            m_prod_neg<=1'b0; m_quot_neg<=1'b0; m_rem_neg<=1'b0; m_div_zero<=1'b0; m_div_overflow<=1'b0;
            original_dividend<=32'd0; multiplier<=32'd0; dividend_reg<=32'd0; divisor_reg<=32'd0; quot_reg<=32'd0;
            multiplicand<=64'd0; prod_reg<=64'd0; rem_reg<=33'd0; mext_result<=32'd0;
        end else begin
            if(state==S_IDLE) begin
                // Latch a new multi-cycle operation and initialize its datapath.
                if(i_mext) begin
                    state<=S_BUSY; step_cnt<=5'd0; m_opsel<=i_opsel; m_is_div<=start_is_div;
                    m_prod_neg<=start_op1_neg^start_op2_neg; m_quot_neg<=start_op1_neg^start_op2_neg; m_rem_neg<=start_op1_neg;
                    m_div_zero<=~|i_op2; m_div_overflow<=(i_opsel==3'b100)&&(i_op1==32'h80000000)&&(i_op2==32'hffffffff);
                    original_dividend<=i_op1; multiplicand<={32'd0,op1_mag}; multiplier<=op2_mag; prod_reg<=64'd0;
                    dividend_reg<=op1_mag; divisor_reg<=op2_mag; quot_reg<=32'd0; rem_reg<=33'd0;
                end
            end else if(state==S_BUSY) begin
                if(m_is_div) begin
                    // Perform one restoring-division iteration
                    rem_reg<=rem_step; quot_reg<=quot_step; dividend_reg<={dividend_reg[30:0],1'b0};

                    if(step_cnt==5'd31) begin state<=S_DONE;
                        // Select the final quotient or remainder, applying signed correction and the defined exceptional results
                        if(m_opsel==3'b100) mext_result<=m_div_zero?32'hffffffff:(m_div_overflow?32'h80000000:corrected_quot);
                        else if(m_opsel==3'b101) mext_result<=m_div_zero?32'hffffffff:quot_step;
                        else if(m_opsel==3'b110) mext_result<=m_div_zero?original_dividend:(m_div_overflow?32'd0:corrected_rem);
                        else mext_result<=m_div_zero?original_dividend:rem_step[31:0];
                    end
                end else begin
                    prod_reg<=product_step; multiplicand<={multiplicand[62:0],1'b0}; multiplier<={1'b0,multiplier[31:1]};
                    
                    // Return the low product for MUL
                    // or the high product portion for the high-half multiply operations
                    if(step_cnt==5'd31) begin state<=S_DONE; mext_result<=(m_opsel==3'b000)?corrected_product[31:0]:corrected_product[63:32]; end
                end
                step_cnt<=next_step; // Advance the iteration count once per busy cycle.
            end else if(state==S_DONE) begin
                // Hold the completed result through cache freezes; consume it only
                // when the EX instruction actually advances.
                if(i_advance) state<=S_IDLE;
            end else state<=S_IDLE;
        end
    end


    // Report busy until the operation is complete
    // Select multi-cycle result for M-extension operations or regular ALU result otherwise
    assign o_busy=i_mext&&(state!=S_DONE);
    assign o_result=i_mext?mext_result:rv32i_result;
endmodule
`default_nettype wire