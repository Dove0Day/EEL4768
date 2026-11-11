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
    // A - B = A + (~B) + 1
    wire [31:0] add_b;
    wire [31:0] add_p;
    wire [31:0] add_g;
    wire [31:0] add_result;

    assign add_b = i_op2 ^ {32{i_sub}}; // use i_sub to see if i_op2 gets inverted
    assign add_p = i_op1 ^ add_b;
    assign add_g = i_op1 & add_b;

    wire [7:0] group_p; // propagate signal for lookahead carry adder
    wire [7:0] group_g; // generate signal for lookahead carry adder

    // lookahead carry adder: 
    // G(i) = A(i)*B(i)
    // P(i) = A(i) XOR B(i)
    // C(i+1) = G(i) + [P(i)*C(i)]

    // expanded for loop
    assign group_p[0] = add_p[0] & add_p[1] & add_p[2] & add_p[3];
    assign group_g[0] = add_g[3] | (add_p[3] & add_g[2]) | (add_p[3] & add_p[2] & add_g[1]) | (add_p[3] & add_p[2] & add_p[1] & add_g[0]);

    assign group_p[1] = add_p[4] & add_p[5] & add_p[6] & add_p[7];
    assign group_g[1] = add_g[7] | (add_p[7] & add_g[6]) | (add_p[7] & add_p[6] & add_g[5]) | (add_p[7] & add_p[6] & add_p[5] & add_g[4]);

    assign group_p[2] = add_p[8] & add_p[9] & add_p[10] & add_p[11];
    assign group_g[2] = add_g[11] | (add_p[11] & add_g[10]) | (add_p[11] & add_p[10] & add_g[9]) | (add_p[11] & add_p[10] & add_p[9] & add_g[8]);

    assign group_p[3] = add_p[12] & add_p[13] & add_p[14] & add_p[15];
    assign group_g[3] = add_g[15] | (add_p[15] & add_g[14]) | (add_p[15] & add_p[14] & add_g[13]) | (add_p[15] & add_p[14] & add_p[13] & add_g[12]);

    assign group_p[4] = add_p[16] & add_p[17] & add_p[18] & add_p[19];
    assign group_g[4] = add_g[19] | (add_p[19] & add_g[18]) | (add_p[19] & add_p[18] & add_g[17]) | (add_p[19] & add_p[18] & add_p[17] & add_g[16]);

    assign group_p[5] = add_p[20] & add_p[21] & add_p[22] & add_p[23];
    assign group_g[5] = add_g[23] | (add_p[23] & add_g[22]) | (add_p[23] & add_p[22] & add_g[21]) | (add_p[23] & add_p[22] & add_p[21] & add_g[20]);

    assign group_p[6] = add_p[24] & add_p[25] & add_p[26] & add_p[27];
    assign group_g[6] = add_g[27] | (add_p[27] & add_g[26]) | (add_p[27] & add_p[26] & add_g[25]) | (add_p[27] & add_p[26] & add_p[25] & add_g[24]);

    assign group_p[7] = add_p[28] & add_p[29] & add_p[30] & add_p[31];
    assign group_g[7] = add_g[31] | (add_p[31] & add_g[30]) | (add_p[31] & add_p[30] & add_g[29]) | (add_p[31] & add_p[30] & add_p[29] & add_g[28]);

    wire [7:0] group_c; // carry into groups
    // C(1) = G(0) + P(0)*C(0)
    // C(2) = G(1) + P(1)*G(0) + P(1)*P(0)*C(0)
    // pattern continues
    assign group_c[0] = i_sub;
    assign group_c[1] = group_g[0] | (group_p[0] & group_c[0]);
    assign group_c[2] = group_g[1] | (group_p[1] & group_g[0]) | (group_p[1] & group_p[0] & group_c[0]);
    assign group_c[3] = group_g[2] | (group_p[2] & group_g[1]) | (group_p[2] & group_p[1] & group_p[0] & group_c[0]) | (group_p[2] & group_p[1] & group_g[0]);
    assign group_c[4] = group_g[3] | (group_p[3] & group_g[2]) | (group_p[3] & group_p[2] & group_g[1]) | (group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[5] = group_g[4] | (group_p[4] & group_g[3]) | (group_p[4] & group_p[3] & group_g[2]) | (group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[4] & group_p[3] & group_p[2] &  group_p[1] & group_g[0]) | (group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[6] = group_g[5] | (group_p[5] & group_g[4]) | (group_p[5] & group_p[4] & group_g[3]) | (group_p[5] & group_p[4] & group_p[3] & group_g[2]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);
    assign group_c[7] = group_g[6] | (group_p[6] & group_g[5]) | (group_p[6] & group_p[5] & group_g[4]) | (group_p[6] & group_p[5] & group_p[4] & group_g[3]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_g[2]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_g[1]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_g[0]) | (group_p[6] & group_p[5] & group_p[4] & group_p[3] & group_p[2] & group_p[1] & group_p[0] & group_c[0]);

// lookahead
// construct sum
wire c1_0;
wire c2_0;
wire c3_0;
wire c1_1;
wire c2_1;
wire c3_1;
wire c1_2;
wire c2_2;
wire c3_2;
wire c1_3;
wire c2_3;
wire c3_3;
wire c1_4;
wire c2_4;
wire c3_4;
wire c1_5;
wire c2_5;
wire c3_5;
wire c1_6;
wire c2_6;
wire c3_6;
wire c1_7;
wire c2_7;
wire c3_7;

// expanded for loop
// Sum(i) = P(i) XOR C(i)

// first bit has a carry or propagates carry entering the group
assign c1_0 = add_g[0] | (add_p[0] & group_c[0]);
assign c2_0 = add_g[1] | (add_p[1] & add_g[0]) | (add_p[1] & add_p[0] & group_c[0]);
assign c3_0 = add_g[2] | (add_p[2] & add_g[1]) | (add_p[2] & add_p[1] & add_g[0]) | (add_p[2] & add_p[1] & add_p[0] & group_c[0]);

// add_result is final addition/subtraction
assign add_result[0] = add_p[0] ^ group_c[0];
assign add_result[1] = add_p[1] ^ c1_0;
assign add_result[2] = add_p[2] ^ c2_0;
assign add_result[3] = add_p[3] ^ c3_0;

assign c1_1 = add_g[4] | (add_p[4] & group_c[1]);
assign c2_1 = add_g[5] | (add_p[5] & add_g[4]) | (add_p[5] & add_p[4] & group_c[1]);
assign c3_1 = add_g[6] | (add_p[6] & add_g[5]) | (add_p[6] & add_p[5] & add_g[4]) | (add_p[6] & add_p[5] & add_p[4] & group_c[1]);

assign add_result[4] = add_p[4] ^ group_c[1];
assign add_result[5] = add_p[5] ^ c1_1;
assign add_result[6] = add_p[6] ^ c2_1;
assign add_result[7] = add_p[7] ^ c3_1;

assign c1_2 = add_g[8] | (add_p[8] & group_c[2]);
assign c2_2 = add_g[9] | (add_p[9] & add_g[8]) | (add_p[9] & add_p[8] & group_c[2]);
assign c3_2 = add_g[10] | (add_p[10] & add_g[9]) | (add_p[10] & add_p[9] & add_g[8]) | (add_p[10] & add_p[9] & add_p[8] & group_c[2]);

assign add_result[8] = add_p[8] ^ group_c[2];
assign add_result[9] = add_p[9] ^ c1_2;
assign add_result[10] = add_p[10] ^ c2_2;
assign add_result[11] = add_p[11] ^ c3_2;

assign c1_3 = add_g[12] | (add_p[12] & group_c[3]);
assign c2_3 = add_g[13] | (add_p[13] & add_g[12]) | (add_p[13] & add_p[12] & group_c[3]);
assign c3_3 = add_g[14] | (add_p[14] & add_g[13]) | (add_p[14] & add_p[13] & add_g[12]) | (add_p[14] & add_p[13] & add_p[12] & group_c[3]);

assign add_result[12] = add_p[12] ^ group_c[3];
assign add_result[13] = add_p[13] ^ c1_3;
assign add_result[14] = add_p[14] ^ c2_3;
assign add_result[15] = add_p[15] ^ c3_3;

assign c1_4 = add_g[16] | (add_p[16] & group_c[4]);
assign c2_4 = add_g[17] | (add_p[17] & add_g[16]) | (add_p[17] & add_p[16] & group_c[4]);
assign c3_4 = add_g[18] | (add_p[18] & add_g[17]) | (add_p[18] & add_p[17] & add_g[16]) | (add_p[18] & add_p[17] & add_p[16] & group_c[4]);

assign add_result[16] = add_p[16] ^ group_c[4];
assign add_result[17] = add_p[17] ^ c1_4;
assign add_result[18] = add_p[18] ^ c2_4;
assign add_result[19] = add_p[19] ^ c3_4;

assign c1_5 = add_g[20] | (add_p[20] & group_c[5]);
assign c2_5 = add_g[21] | (add_p[21] & add_g[20]) | (add_p[21] & add_p[20] & group_c[5]);
assign c3_5 = add_g[22] | (add_p[22] & add_g[21]) | (add_p[22] & add_p[21] & add_g[20]) | (add_p[22] & add_p[21] & add_p[20] & group_c[5]);

assign add_result[20] = add_p[20] ^ group_c[5];
assign add_result[21] = add_p[21] ^ c1_5;
assign add_result[22] = add_p[22] ^ c2_5;
assign add_result[23] = add_p[23] ^ c3_5;

assign c1_6 = add_g[24] | (add_p[24] & group_c[6]);
assign c2_6 = add_g[25] | (add_p[25] & add_g[24]) | (add_p[25] & add_p[24] & group_c[6]);
assign c3_6 = add_g[26] | (add_p[26] & add_g[25]) | (add_p[26] & add_p[25] & add_g[24]) | (add_p[26] & add_p[25] & add_p[24] & group_c[6]);

assign add_result[24] = add_p[24] ^ group_c[6];
assign add_result[25] = add_p[25] ^ c1_6;
assign add_result[26] = add_p[26] ^ c2_6;
assign add_result[27] = add_p[27] ^ c3_6;

assign c1_7 = add_g[28] | (add_p[28] & group_c[7]);
assign c2_7 = add_g[29] | (add_p[29] & add_g[28]) | (add_p[29] & add_p[28] & group_c[7]);
assign c3_7 = add_g[30] | (add_p[30] & add_g[29]) | (add_p[30] & add_p[29] & add_g[28]) | (add_p[30] & add_p[29] & add_p[28] & group_c[7]);

assign add_result[28] = add_p[28] ^ group_c[7];
assign add_result[29] = add_p[29] ^ c1_7;
assign add_result[30] = add_p[30] ^ c2_7;
assign add_result[31] = add_p[31] ^ c3_7;

// left barrel shifter by 1, 2, 4, 8, 16
wire [31:0] sll_1;
wire [31:0] sll_2;
wire [31:0] sll_4;
wire [31:0] sll_8;
wire [31:0] sll_16;

// if bit 0 of shamt is 1, shift 1
assign sll_1 = i_op2[0] ? {i_op1[30:0], 1'b0} : i_op1;
assign sll_2 = i_op2[1] ? {sll_1[29:0], 2'b0} : sll_1;
assign sll_4 = i_op2[2] ? {sll_2[27:0], 4'b0} : sll_2;
assign sll_8 = i_op2[3] ? {sll_4[23:0], 8'b0} : sll_4;
assign sll_16 = i_op2[4] ? {sll_8[15:0], 16'b0} : sll_8;

// right barrel shifter, i_arith = 0 (SRL, fill w/ zero), i_arith = 1 (SRA, fill w/ sign bit)
wire [31:0] sr_1;
wire [31:0] sr_2;
wire [31:0] sr_4;
wire [31:0] sr_8;
wire [31:0] sr_16;

assign sr_1 = i_op2[0] ? {(i_arith ? i_op1[31] : 1'b0), i_op1[31:1]} : i_op1;
assign sr_2 = i_op2[1] ? {{2{(i_arith ? sr_1[31] : 1'b0)}}, sr_1[31:2]} : sr_1;
assign sr_4 = i_op2[2] ? {{4{(i_arith ? sr_2[31] : 1'b0)}}, sr_2[31:4]} : sr_2;
assign sr_8 = i_op2[3] ? {{8{(i_arith ? sr_4[31] : 1'b0)}}, sr_4[31:8]} : sr_4;
assign sr_16 = i_op2[4] ? {{16{(i_arith ? sr_8[31] : 1'b0)}}, sr_8[31:16]} : sr_8;

// comparator, eq_above[n] bits more significant than n equal
// lt_term[n] bit n is first diff bit and op1[n] = 0, op2[n] = 1
wire [31:0] eq_above;
wire [31:0] lt_term;

assign eq_above[31] = 1'b1;

// expanded for loop
assign eq_above[0] = eq_above[1] & ~(i_op1[1] ^ i_op2[1]);
assign eq_above[1] = eq_above[2] & ~(i_op1[2] ^ i_op2[2]);
assign eq_above[2] = eq_above[3] & ~(i_op1[3] ^ i_op2[3]);
assign eq_above[3] = eq_above[4] & ~(i_op1[4] ^ i_op2[4]);
assign eq_above[4] = eq_above[5] & ~(i_op1[5] ^ i_op2[5]);
assign eq_above[5] = eq_above[6] & ~(i_op1[6] ^ i_op2[6]);
assign eq_above[6] = eq_above[7] & ~(i_op1[7] ^ i_op2[7]);
assign eq_above[7] = eq_above[8] & ~(i_op1[8] ^ i_op2[8]);
assign eq_above[8] = eq_above[9] & ~(i_op1[9] ^ i_op2[9]);
assign eq_above[9] = eq_above[10] & ~(i_op1[10] ^ i_op2[10]);
assign eq_above[10] = eq_above[11] & ~(i_op1[11] ^ i_op2[11]);
assign eq_above[11] = eq_above[12] & ~(i_op1[12] ^ i_op2[12]);
assign eq_above[12] = eq_above[13] & ~(i_op1[13] ^ i_op2[13]);
assign eq_above[13] = eq_above[14] & ~(i_op1[14] ^ i_op2[14]);
assign eq_above[14] = eq_above[15] & ~(i_op1[15] ^ i_op2[15]);
assign eq_above[15] = eq_above[16] & ~(i_op1[16] ^ i_op2[16]);
assign eq_above[16] = eq_above[17] & ~(i_op1[17] ^ i_op2[17]);
assign eq_above[17] = eq_above[18] & ~(i_op1[18] ^ i_op2[18]);
assign eq_above[18] = eq_above[19] & ~(i_op1[19] ^ i_op2[19]);
assign eq_above[19] = eq_above[20] & ~(i_op1[20] ^ i_op2[20]);
assign eq_above[20] = eq_above[21] & ~(i_op1[21] ^ i_op2[21]);
assign eq_above[21] = eq_above[22] & ~(i_op1[22] ^ i_op2[22]);
assign eq_above[22] = eq_above[23] & ~(i_op1[23] ^ i_op2[23]);
assign eq_above[23] = eq_above[24] & ~(i_op1[24] ^ i_op2[24]);
assign eq_above[24] = eq_above[25] & ~(i_op1[25] ^ i_op2[25]);
assign eq_above[25] = eq_above[26] & ~(i_op1[26] ^ i_op2[26]);
assign eq_above[26] = eq_above[27] & ~(i_op1[27] ^ i_op2[27]);
assign eq_above[27] = eq_above[28] & ~(i_op1[28] ^ i_op2[28]);
assign eq_above[28] = eq_above[29] & ~(i_op1[29] ^ i_op2[29]);
assign eq_above[29] = eq_above[30] & ~(i_op1[30] ^ i_op2[30]);
assign eq_above[30] = eq_above[31] & ~(i_op1[31] ^ i_op2[31]);

assign lt_term = eq_above & ~i_op1 & i_op2;

wire unsigned_lt;
wire signed_lt;

assign unsigned_lt = |lt_term;

// if diff signs, neg operand smaller, else unsigned order same as signed order
assign signed_lt = (i_op1[31] ^ i_op2[31]) ? i_op1[31] : unsigned_lt;

// compare outputs
assign o_eq = ~|(i_op1 ^ i_op2);
assign o_slt = i_unsigned ? unsigned_lt : signed_lt; // phase 4: removed $signed

// phase 3: compare output for SLTU
// i_opsel == 3'b011 check that SLTU is being performed by ALU
// if i_op1 < i_op2, unsigned_lt (comp result) is 1
// i_op1 >= i_op2, unsigned_lt is 0 (hence 1'b0)
//phase 5:
//assign o_sltu = (i_opsel == 3'b011) ? unsigned_lt : 1'b0; // phase 4: comparison operator removed

// slt/sltu results
wire [31:0] slt_result;
// phase 4: removed sltu wire, decoder sets i_unsigned = 0, i_unsigned now chooses sign instead of i_opsel
wire [31:0] sltu_result;

assign slt_result = {31'b0, signed_lt};
// phase 4: removed sltu assign, same reason as sltu wire removed
assign sltu_result = {31'b0, unsigned_lt};

// final ALU results
//assign o_result = (i_opsel == 3'b000) ? add_result : (i_opsel == 3'b001) ? sll_16 : (i_opsel == 3'b010) ? slt_result : (i_opsel == 3'b011) ? sltu_result : (i_opsel == 3'b100) ? (i_op1 ^ i_op2) : (i_opsel == 3'b101) ? sr_16 : (i_opsel == 3'b110) ? (i_op1 | i_op2) : (i_op1 & i_op2);

//Start of Phase 6 Implementation
localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_BUSY = 2'd1;
    localparam [1:0] S_DONE = 2'd2;

    // Signedness rules based on i_opsel (funct3):
    // Mul: 000=mul, 001=mulh (s*s), 010=mulhsu (s*u), 011=mulhu (u*u)
    // Div: 100=div (s/s), 101=divu (u/u), 110=rem (s%s), 111=remu (u%u)
    wire is_div;
    wire op1_signed;
    wire op2_signed;
    wire op1_neg;
    wire op2_neg;

    assign is_div     = i_opsel[2];
    assign op1_signed = is_div ? ~i_opsel[0] : ((i_opsel == 3'b001) || (i_opsel == 3'b010));
    assign op2_signed = is_div ? ~i_opsel[0] : (i_opsel == 3'b001);
    assign op1_neg    = op1_signed & i_op1[31];
    assign op2_neg    = op2_signed & i_op2[31];

    // Convert negative signed operands to unsigned magnitudes (two's complement)
    wire [31:0] op1_mag;
    wire [31:0] op2_mag;
    assign op1_mag = op1_neg ? (~i_op1 + 32'd1) : i_op1;
    assign op2_mag = op2_neg ? (~i_op2 + 32'd1) : i_op2;

    reg [ 1:0] state;
    reg [ 4:0] step_cnt;

    // Shift-and-add multiplier registers (Section 4.3.1, Figure 3)
    reg [63:0] multiplicand;
    reg [31:0] multiplier;
    reg [63:0] prod_reg;

    // Restoring divider registers (Section 4.3.2)
    reg [31:0] dividend_reg;
    reg [31:0] divisor_reg;
    reg [31:0] quot_reg;
    reg [31:0] rem_reg;

    // Next-step combinational logic for restoring division
    wire [32:0] rem_shift;
    wire        rem_ge;
    wire [31:0] rem_next;

    assign rem_shift = {rem_reg, dividend_reg[31]};
    assign rem_ge    = (rem_shift >= {1'b0, divisor_reg});
    assign rem_next  = rem_ge ? (rem_shift[31:0] - divisor_reg) : rem_shift[31:0];

    always @(posedge i_clk) begin
        if (i_rst) begin
            state        <= S_IDLE;
            step_cnt     <= 5'd0;
            multiplicand <= 64'd0;
            multiplier   <= 32'd0;
            prod_reg     <= 64'd0;
            dividend_reg <= 32'd0;
            divisor_reg  <= 32'd0;
            quot_reg     <= 32'd0;
            rem_reg      <= 32'd0;
        end else begin
            if (state == S_IDLE) begin
                if (i_mext) begin
                    state        <= S_BUSY;
                    step_cnt     <= 5'd0;
                    multiplicand <= {32'd0, op1_mag};
                    multiplier   <= op2_mag;
                    prod_reg     <= 64'd0;
                    dividend_reg <= op1_mag;
                    divisor_reg  <= op2_mag;
                    quot_reg     <= 32'd0;
                    rem_reg      <= 32'd0;
                end
            end else if (state == S_BUSY) begin
                // Multiplier step: add if LSB is 1, shift multiplicand left 1, multiplier right 1
                if (multiplier[0]) begin
                    prod_reg <= prod_reg + multiplicand;
                end
                multiplicand <= {multiplicand[62:0], 1'b0};
                multiplier   <= {1'b0, multiplier[31:1]};

                // Divider step: shift in MSB of dividend, subtract divisor if >=
                rem_reg      <= rem_next;
                quot_reg     <= {quot_reg[30:0], rem_ge};
                dividend_reg <= {dividend_reg[30:0], 1'b0};

                if (step_cnt == 5'd31) begin
                    state <= S_DONE;
                end
                step_cnt <= step_cnt + 5'd1;
            end else if (state == S_DONE) begin
                // Hold result until instruction advances out of EX
                if (i_advance || !i_mext) begin
                    state <= S_IDLE;
                end
            end else begin
                state <= S_IDLE;
            end
        end
    end

    // Sign correction and special-case outputs (divide by 0 and -2^31 / -1 overflow)
    wire        prod_neg;
    wire [63:0] final_prod;
    assign prod_neg   = op1_neg ^ op2_neg;
    assign final_prod = prod_neg ? (~prod_reg + 64'd1) : prod_reg;

    wire        div_by_zero;
    wire        div_overflow;
    wire        quot_neg;
    wire [31:0] signed_quot;
    wire [31:0] signed_rem;
    wire [31:0] final_quot;
    wire [31:0] final_rem;

    assign div_by_zero  = (i_op2 == 32'd0);
    assign div_overflow = (i_op1 == 32'h8000_0000) && (i_op2 == 32'hFFFF_FFFF) && ~i_opsel[0];
    assign quot_neg     = op1_neg ^ op2_neg;

    assign signed_quot = quot_neg ? (~quot_reg + 32'd1) : quot_reg;
    assign signed_rem  = op1_neg  ? (~rem_reg  + 32'd1) : rem_reg;

    assign final_quot =
        div_by_zero  ? 32'hFFFF_FFFF :
        div_overflow ? 32'h8000_0000 :
        signed_quot;

    assign final_rem =
        div_by_zero  ? i_op1 :
        div_overflow ? 32'h0000_0000 :
        signed_rem;

    wire [31:0] mext_result;
    assign mext_result =
        (i_opsel == 3'b000) ? final_prod[31:0]  : // mul
        (i_opsel == 3'b001) ? final_prod[63:32] : // mulh
        (i_opsel == 3'b010) ? final_prod[63:32] : // mulhsu
        (i_opsel == 3'b011) ? final_prod[63:32] : // mulhu
        (i_opsel == 3'b100) ? final_quot        : // div
        (i_opsel == 3'b101) ? final_quot        : // divu
        (i_opsel == 3'b110) ? final_rem         : // rem
                              final_rem;          // remu

    assign o_busy = i_mext && (state != S_DONE);

//End of Implementation

// final mux correction, source ChatGPT
//If `i_mext` is high, output `mext_result`; otherwise use Phase 5 mux
assign o_result =
    i_mext              ? mext_result :
    (i_opsel == 3'b000) ? add_result :
    (i_opsel == 3'b001) ? sll_16 :
    (i_opsel == 3'b010) ? slt_result :
    (i_opsel == 3'b011) ? sltu_result :
    (i_opsel == 3'b100) ? (i_op1 ^ i_op2) :
    (i_opsel == 3'b101) ? sr_16 :
    (i_opsel == 3'b110) ? (i_op1 | i_op2) :
                           (i_op1 & i_op2);

endmodule

`default_nettype wire
