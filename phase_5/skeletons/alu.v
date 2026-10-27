`default_nettype none

// The arithmetic logic unit (ALU) is responsible for performing the core
// calculations of the processor. It takes two 32-bit operands and outputs
// a 32 bit result based on the selection operation - addition, comparison,
// shift, or logical operation. This ALU is a purely combinational block, so
// you should not attempt to add any registers or pipeline it.
module alu (
    // Major operation selection.
    // 3'b000: addition/subtraction if `i_sub` asserted
    // 3'b001: shift left logical
    // 3'b010: set less than
    // 3'b011: set less than unsigned
    // 3'b100: exclusive or
    // 3'b101: shift right logical/arithmetic if `i_arith` asserted
    // 3'b110: or
    // 3'b111: and
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

    // phase 3: I'm adding an o_sltu since the port is needed for SLTU signal
    output wire        o_sltu
);
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
assign o_sltu = (i_opsel == 3'b011) ? unsigned_lt : 1'b0; // phase 4: comparison operator removed

// slt/sltu results
wire [31:0] slt_result;
// phase 4: removed sltu wire, decoder sets i_unsigned = 0, i_unsigned now chooses sign instead of i_opsel
wire [31:0] sltu_result;

assign slt_result = {31'b0, signed_lt};
// phase 4: removed sltu assign, same reason as sltu wire removed
assign sltu_result = {31'b0, unsigned_lt};

// final ALU results
//assign o_result = (i_opsel == 3'b000) ? add_result : (i_opsel == 3'b001) ? sll_16 : (i_opsel == 3'b010) ? slt_result : (i_opsel == 3'b011) ? sltu_result : (i_opsel == 3'b100) ? (i_op1 ^ i_op2) : (i_opsel == 3'b101) ? sr_16 : (i_opsel == 3'b110) ? (i_op1 | i_op2) : (i_op1 & i_op2);

// final mux correction, source ChatGPT
assign o_result =
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
