`default_nettype none

// The floating-point unit implements the RISC-V F extension (single
// precision, IEEE 754-2008) and the Zicsr instructions for its control and
// status register fcsr. It sits in the execute stage beside the ALU and the
// multiply/divide unit, and decodes the details of its own instructions from
// the instruction word.
//
// It owns all F-extension state: fcsr, holding the dynamic rounding mode frm
// (fcsr[7:5]) and the accrued exception flags fflags (fcsr[4:0] = NV DZ OF
// UF NX). Floating-point exceptions never trap; they only set flags, which
// stay set until software clears them through a CSR instruction.
//
// fcsr only changes on a rising edge where the instruction in execute
// actually moves on to the memory stage (`i_advance`). An instruction can sit
// in execute for several cycles (for example while a cache miss freezes the
// pipeline); committing its flags or CSR write on every one of those cycles
// would make a CSR instruction read back its own write.
module fpu (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset. Clears fcsr (frm = round to nearest,
    // ties to even; no flags set).
    input  wire        i_rst,
    // The instruction word in the execute stage.
    input  wire [31:0] i_inst,
    // Asserted when `i_inst` is a valid, legal floating-point unit
    // instruction (decoder `o_fpu`): every OP-FP and fused multiply-add
    // instruction and the CSR instructions on fflags/frm/fcsr.
    input  wire        i_valid,
    // Asserted when the instruction in execute advances to the memory stage
    // on the next rising edge. Side effects (fcsr updates) happen only then.
    input  wire        i_advance,
    // Floating-point source operands (rs1, rs2, rs3), raw IEEE bit patterns.
    input  wire [31:0] i_frs1,
    input  wire [31:0] i_frs2,
    input  wire [31:0] i_frs3,
    // Integer source operand (forwarded rs1), used by fmv.w.x, fcvt.s.w[u]
    // and the register forms of the CSR instructions.
    input  wire [31:0] i_xrs1,
    // Result for instructions that write a floating-point register.
    output wire [31:0] o_fp_result,
    // Result for instructions that write an integer register: fmv.x.w,
    // fclass.s, feq/flt/fle.s, fcvt.w[u].s, and the old CSR value.
    output wire [31:0] o_int_result,
    // The accrued exception flags as they will be after this instruction
    // (reported in the retire trace).
    output wire [ 4:0] o_fflags,
    // Asserted while a multi-cycle operation (fdiv.s/fsqrt.s) is in
    // progress and the instruction must stay in execute.
    output wire        o_busy,
    // Asserted when a rounding instruction selects the dynamic rounding mode
    // (rm = 111) while frm holds a reserved value (101-111). The instruction
    // traps as illegal and changes no state.
    output wire        o_rm_trap
);

    // Default quiet NaN result used when operation produces a NaN
    localparam [31:0] CANONICAL_NAN = 32'h7fc0_0000;

    // RISC-V instruction opcode constants
    localparam [6:0]  OPC_OP_FP = 7'b1010011;
    localparam [6:0]  OPC_MADD  = 7'b1000011;
    localparam [6:0]  OPC_MSUB  = 7'b1000111;
    localparam [6:0]  OPC_NMSUB = 7'b1001011;
    localparam [6:0]  OPC_NMADD = 7'b1001111;
    localparam [6:0]  OPC_SYSTEM = 7'b1110011;

    // Extract commonly used fields from instruction word
    wire [6:0] opcode = i_inst[6:0];
    wire [2:0] funct3 = i_inst[14:12];
    wire [4:0] rs1_field = i_inst[19:15];
    wire [4:0] rs2_field = i_inst[24:20];
    wire [6:0] funct7 = i_inst[31:25];
    wire [11:0] csr_addr = i_inst[31:20];

    // Floating-point control and status state
    // accrued_flags contains NV, DZ, OF, UF, and NX, frm stores the rounding mode
    reg [4:0] accrued_flags;
    reg [2:0] frm;

    // Identify CSR instructions and fused multiply-add family instructions
    wire is_csr = (opcode == OPC_SYSTEM) && (funct3 != 3'b000);
    wire is_fused = (opcode == OPC_MADD) || (opcode == OPC_MSUB) ||
                    (opcode == OPC_NMSUB) || (opcode == OPC_NMADD);

    // These instruction encodings use a rounding mode
    wire instruction_rounds = is_fused ||
        ((opcode == OPC_OP_FP) &&
         ((funct7 == 7'b0000000) || (funct7 == 7'b0000100) ||
          (funct7 == 7'b0001000) || (funct7 == 7'b0001100) ||
          (funct7 == 7'b0101100) || (funct7 == 7'b1100000) ||
          (funct7 == 7'b1101000)));

    // rm = 111 selects the dynamic rounding mode stored in frm
    wire [2:0] selected_rm = (funct3 == 3'b111) ? frm : funct3;

    // Dynamic rounding mode values 101, 110, and 111 are reserved
    // Can Signal an illegal rounding-mode use
    assign o_rm_trap = i_valid && instruction_rounds &&
                       (funct3 == 3'b111) && (frm[2] && (frm[1] || frm[0]));


    // Operand classification

    // Classify each floating-point operand by examining exponent/fraction
    // All-zero exponent identifies zero or a subnormal value
    wire a_exp_zero = ~|i_frs1[30:23];
    wire b_exp_zero = ~|i_frs2[30:23];
    wire c_exp_zero = ~|i_frs3[30:23];

    // An all-one exponent identifies an infinity or NaN.
    wire a_exp_ones = &i_frs1[30:23];
    wire b_exp_ones = &i_frs2[30:23];
    wire c_exp_ones = &i_frs3[30:23];


    // A zero fraction distinguishes zero from subnormal / infinity from NaN
    wire a_frac_zero = ~|i_frs1[22:0];
    wire b_frac_zero = ~|i_frs2[22:0];
    wire c_frac_zero = ~|i_frs3[22:0];
    wire a_zero = a_exp_zero && a_frac_zero;
    wire b_zero = b_exp_zero && b_frac_zero;
    wire c_zero = c_exp_zero && c_frac_zero;
    wire a_inf = a_exp_ones && a_frac_zero;
    wire b_inf = b_exp_ones && b_frac_zero;
    wire c_inf = c_exp_ones && c_frac_zero;
    wire a_nan = a_exp_ones && !a_frac_zero;
    wire b_nan = b_exp_ones && !b_frac_zero;
    wire c_nan = c_exp_ones && !c_frac_zero;
    wire a_snan = a_nan && !i_frs1[22];
    wire b_snan = b_nan && !i_frs2[22];
    wire c_snan = c_nan && !i_frs3[22];

    wire both_zero = a_zero && b_zero;
    wire fp_equal = both_zero || (i_frs1 == i_frs2);

    // For negative values, the encoded magnitude order is reversed
    // If signs differ, the negative operand is less, otherwise compare magnitudes
    wire fp_less = !both_zero &&
        ((i_frs1[31] != i_frs2[31]) ? i_frs1[31] :
         (i_frs1[31] ? (i_frs1[30:0] > i_frs2[30:0]) :
                       (i_frs1[30:0] < i_frs2[30:0])));

    // 24x24 unsigned significand multiplier built from partial products
    wire [23:0] sig_a = {~a_exp_zero, i_frs1[22:0]};
    wire [23:0] sig_b = {~b_exp_zero, i_frs2[22:0]};
    wire [47:0] partial [23:0];
    wire [47:0] product_sum [24:0];

    // Accumulate partial products to form the 48-bit significand product
    assign product_sum[0] = 48'd0;
    assign partial[0] = sig_b[0] ? {24'd0, sig_a} : 48'd0;
    assign product_sum[1] = product_sum[0] + partial[0];
    assign partial[1] = sig_b[1] ? {23'd0, sig_a, 1'd0} : 48'd0;
    assign product_sum[2] = product_sum[1] + partial[1];
    assign partial[2] = sig_b[2] ? {22'd0, sig_a, 2'd0} : 48'd0;
    assign product_sum[3] = product_sum[2] + partial[2];
    assign partial[3] = sig_b[3] ? {21'd0, sig_a, 3'd0} : 48'd0;
    assign product_sum[4] = product_sum[3] + partial[3];
    assign partial[4] = sig_b[4] ? {20'd0, sig_a, 4'd0} : 48'd0;
    assign product_sum[5] = product_sum[4] + partial[4];
    assign partial[5] = sig_b[5] ? {19'd0, sig_a, 5'd0} : 48'd0;
    assign product_sum[6] = product_sum[5] + partial[5];
    assign partial[6] = sig_b[6] ? {18'd0, sig_a, 6'd0} : 48'd0;
    assign product_sum[7] = product_sum[6] + partial[6];
    assign partial[7] = sig_b[7] ? {17'd0, sig_a, 7'd0} : 48'd0;
    assign product_sum[8] = product_sum[7] + partial[7];
    assign partial[8] = sig_b[8] ? {16'd0, sig_a, 8'd0} : 48'd0;
    assign product_sum[9] = product_sum[8] + partial[8];
    assign partial[9] = sig_b[9] ? {15'd0, sig_a, 9'd0} : 48'd0;
    assign product_sum[10] = product_sum[9] + partial[9];
    assign partial[10] = sig_b[10] ? {14'd0, sig_a, 10'd0} : 48'd0;
    assign product_sum[11] = product_sum[10] + partial[10];
    assign partial[11] = sig_b[11] ? {13'd0, sig_a, 11'd0} : 48'd0;
    assign product_sum[12] = product_sum[11] + partial[11];
    assign partial[12] = sig_b[12] ? {12'd0, sig_a, 12'd0} : 48'd0;
    assign product_sum[13] = product_sum[12] + partial[12];
    assign partial[13] = sig_b[13] ? {11'd0, sig_a, 13'd0} : 48'd0;
    assign product_sum[14] = product_sum[13] + partial[13];
    assign partial[14] = sig_b[14] ? {10'd0, sig_a, 14'd0} : 48'd0;
    assign product_sum[15] = product_sum[14] + partial[14];
    assign partial[15] = sig_b[15] ? {9'd0, sig_a, 15'd0} : 48'd0;
    assign product_sum[16] = product_sum[15] + partial[15];
    assign partial[16] = sig_b[16] ? {8'd0, sig_a, 16'd0} : 48'd0;
    assign product_sum[17] = product_sum[16] + partial[16];
    assign partial[17] = sig_b[17] ? {7'd0, sig_a, 17'd0} : 48'd0;
    assign product_sum[18] = product_sum[17] + partial[17];
    assign partial[18] = sig_b[18] ? {6'd0, sig_a, 18'd0} : 48'd0;
    assign product_sum[19] = product_sum[18] + partial[18];
    assign partial[19] = sig_b[19] ? {5'd0, sig_a, 19'd0} : 48'd0;
    assign product_sum[20] = product_sum[19] + partial[19];
    assign partial[20] = sig_b[20] ? {4'd0, sig_a, 20'd0} : 48'd0;
    assign product_sum[21] = product_sum[20] + partial[20];
    assign partial[21] = sig_b[21] ? {3'd0, sig_a, 21'd0} : 48'd0;
    assign product_sum[22] = product_sum[21] + partial[21];
    assign partial[22] = sig_b[22] ? {2'd0, sig_a, 22'd0} : 48'd0;
    assign product_sum[23] = product_sum[22] + partial[22];
    assign partial[23] = sig_b[23] ? {1'd0, sig_a, 23'd0} : 48'd0;
    assign product_sum[24] = product_sum[23] + partial[23];
    wire [47:0] significand_product = product_sum[24];

    // Classification result as one-hot result bit
    // The output bit positions correspond to the FCLASS.S categories
    reg [31:0] class_result;
    always @(*) begin
        case ({a_nan, a_snan, a_inf, a_zero, a_exp_zero, i_frs1[31]})
            6'b110000: class_result = 32'h0000_0100;
            6'b100000: class_result = 32'h0000_0200;
            6'b001001: class_result = 32'h0000_0001;
            6'b001000: class_result = 32'h0000_0080;
            6'b000101: class_result = 32'h0000_0008;
            6'b000100: class_result = 32'h0000_0010;
            6'b000011: class_result = 32'h0000_0004;
            6'b000010: class_result = 32'h0000_0020;
            6'b000001: class_result = 32'h0000_0002;
            default:   class_result = 32'h0000_0040;
        endcase
    end

    // CSR read/modify/write values.
    wire [31:0] csr_old = (csr_addr == 12'h001) ? {27'd0, accrued_flags} :
                          (csr_addr == 12'h002) ? {29'd0, frm} :
                          (csr_addr == 12'h003) ? {24'd0, frm, accrued_flags} : 32'd0;
    wire [31:0] csr_source = funct3[2] ? {27'd0, rs1_field} : i_xrs1;


    // Compute the new CSR value and whether the instruction writes it
    // CSRRW replaces, CSRRS sets selected bits, and CSRRC clears selected bits
    reg [31:0] csr_new;
    reg csr_write_en;
    always @(*) begin
        case (funct3)
            3'b001, 3'b101: begin csr_new = csr_source; csr_write_en = 1'b1; end
            3'b010, 3'b110: begin csr_new = csr_old | csr_source; csr_write_en = |rs1_field; end
            3'b011, 3'b111: begin csr_new = csr_old & ~csr_source; csr_write_en = |rs1_field; end
            default: begin csr_new = csr_old; csr_write_en = 1'b0; end
        endcase
    end


    // ---------------------------------------------------------------------
    // Finite FADD.S datapath
    // ---------------------------------------------------------------------
    // Subnormal operands use an effective exponent of 1 and no hidden bit.
    // Three low bits are carried through alignment: guard, round and sticky
    wire fadd_is_sub = (funct7 == 7'b0000100);
    wire fadd_b_sign = i_frs2[31] ^ fadd_is_sub;
    wire [7:0] fadd_exp_a = a_exp_zero ? 8'd1 : i_frs1[30:23];
    wire [7:0] fadd_exp_b = b_exp_zero ? 8'd1 : i_frs2[30:23];
    wire [23:0] fadd_sig_a = {~a_exp_zero, i_frs1[22:0]};
    wire [23:0] fadd_sig_b = {~b_exp_zero, i_frs2[22:0]};


    // Select the operand with the larger exponent/significand as alignment reference
    //Its sign and exponent are carried forward
    wire fadd_a_ge_b = (fadd_exp_a > fadd_exp_b) ||
                       ((fadd_exp_a == fadd_exp_b) && (fadd_sig_a >= fadd_sig_b));
    wire [7:0] fadd_exp_large = fadd_a_ge_b ? fadd_exp_a : fadd_exp_b;
    wire [7:0] fadd_exp_small = fadd_a_ge_b ? fadd_exp_b : fadd_exp_a;
    wire [23:0] fadd_sig_large = fadd_a_ge_b ? fadd_sig_a : fadd_sig_b;
    wire [23:0] fadd_sig_small = fadd_a_ge_b ? fadd_sig_b : fadd_sig_a;
    wire fadd_sign_large = fadd_a_ge_b ? i_frs1[31] : fadd_b_sign;
    wire fadd_sign_small = fadd_a_ge_b ? fadd_b_sign : i_frs1[31];
    wire [7:0] fadd_exp_diff_full = fadd_exp_large - fadd_exp_small;
    wire [4:0] fadd_exp_diff = (fadd_exp_diff_full > 8'd31) ?
                                5'd31 : fadd_exp_diff_full[4:0];

    // Extend the smaller significand with three rounding bits, then shift it right by exponent difference
    // Each stage also jams any shifted out bits into the low sticky bit
    wire [27:0] fadd_small_0 = {1'b0, fadd_sig_small, 3'b000};
    wire [27:0] fadd_small_1 = fadd_exp_diff[0] ?
        {1'b0, fadd_small_0[27:2], |fadd_small_0[1:0]} : fadd_small_0;
    wire [27:0] fadd_small_2 = fadd_exp_diff[1] ?
        {2'b00, fadd_small_1[27:3], |fadd_small_1[2:0]} : fadd_small_1;
    wire [27:0] fadd_small_4 = fadd_exp_diff[2] ?
        {4'b0000, fadd_small_2[27:5], |fadd_small_2[4:0]} : fadd_small_2;
    wire [27:0] fadd_small_8 = fadd_exp_diff[3] ?
        {8'b0, fadd_small_4[27:9], |fadd_small_4[8:0]} : fadd_small_4;
    wire [27:0] fadd_small_16 = fadd_exp_diff[4] ?
        {16'b0, fadd_small_8[27:17], |fadd_small_8[16:0]} : fadd_small_8;
    wire [27:0] fadd_large_ext = {1'b0, fadd_sig_large, 3'b000};
    wire fadd_same_sign = ~(fadd_sign_large ^ fadd_sign_small);
    wire [27:0] fadd_sum_raw = fadd_same_sign ?
        (fadd_large_ext + fadd_small_16) :
        (fadd_large_ext - fadd_small_16);

    // Leading-zero count for cancellation after unlike-sign addition
    reg [4:0] fadd_lshift;
    always @(*) begin
        casez (fadd_sum_raw[26:3])
            24'b1???????????????????????: fadd_lshift = 5'd0;
            24'b01??????????????????????: fadd_lshift = 5'd1;
            24'b001?????????????????????: fadd_lshift = 5'd2;
            24'b0001????????????????????: fadd_lshift = 5'd3;
            24'b00001???????????????????: fadd_lshift = 5'd4;
            24'b000001??????????????????: fadd_lshift = 5'd5;
            24'b0000001?????????????????: fadd_lshift = 5'd6;
            24'b00000001????????????????: fadd_lshift = 5'd7;
            24'b000000001???????????????: fadd_lshift = 5'd8;
            24'b0000000001??????????????: fadd_lshift = 5'd9;
            24'b00000000001?????????????: fadd_lshift = 5'd10;
            24'b000000000001????????????: fadd_lshift = 5'd11;
            24'b0000000000001???????????: fadd_lshift = 5'd12;
            24'b00000000000001??????????: fadd_lshift = 5'd13;
            24'b000000000000001?????????: fadd_lshift = 5'd14;
            24'b0000000000000001????????: fadd_lshift = 5'd15;
            24'b00000000000000001???????: fadd_lshift = 5'd16;
            24'b000000000000000001??????: fadd_lshift = 5'd17;
            24'b0000000000000000001?????: fadd_lshift = 5'd18;
            24'b00000000000000000001????: fadd_lshift = 5'd19;
            24'b000000000000000000001???: fadd_lshift = 5'd20;
            24'b0000000000000000000001??: fadd_lshift = 5'd21;
            24'b00000000000000000000001?: fadd_lshift = 5'd22;
            24'b000000000000000000000001: fadd_lshift = 5'd23;
            default:                     fadd_lshift = 5'd24;
        endcase
    end

    // Limit the left-normalization shift so the exponent does not fall below minimum representable subnormal exponent
    wire [7:0] fadd_max_lshift_full = fadd_exp_large - 8'd1;
    wire [4:0] fadd_max_lshift = (fadd_exp_large <= 8'd1) ? 5'd0 :
        ((fadd_max_lshift_full > 8'd24) ? 5'd24 :
         fadd_max_lshift_full[4:0]);


    // Use whichever is smaller: shift needed to normalize the sum / maximum shift permitted by the available exponent
    wire [4:0] fadd_shift_use = (fadd_lshift > fadd_max_lshift) ?
                                  fadd_max_lshift : fadd_lshift;

    // Apply the selected left shift as conditional 1-, 2-, 4-, 8-, and 16-bit stages
    // Result retains the full datapath width
    wire [27:0] fadd_norm_1 = fadd_shift_use[0] ?
        {fadd_sum_raw[26:0],1'b0} : fadd_sum_raw;
    wire [27:0] fadd_norm_2 = fadd_shift_use[1] ?
        {fadd_norm_1[25:0],2'b00} : fadd_norm_1;
    wire [27:0] fadd_norm_4 = fadd_shift_use[2] ?
        {fadd_norm_2[23:0],4'b0000} : fadd_norm_2;
    wire [27:0] fadd_norm_8 = fadd_shift_use[3] ?
        {fadd_norm_4[19:0],8'b0} : fadd_norm_4;
    wire [27:0] fadd_norm_16 = fadd_shift_use[4] ?
        {fadd_norm_8[11:0],16'b0} : fadd_norm_8;
    wire [8:0] fadd_exp_left = {1'b0,fadd_exp_large} - {4'd0,fadd_shift_use};

    // Same-sign addition may create a carry. Shift right once and preserve
    // all discarded information in the sticky bit.
    wire [27:0] fadd_norm = fadd_sum_raw[27] ?
        {1'b0, fadd_sum_raw[27:2], |fadd_sum_raw[1:0]} : fadd_norm_16;
    wire [8:0] fadd_exp_norm = fadd_sum_raw[27] ?
        ({1'b0,fadd_exp_large} + 9'd1) : fadd_exp_left;

    // Split the normalized result into retained significand and rounding bits
    wire [23:0] fadd_retained = fadd_norm[26:3];
    wire fadd_guard = fadd_norm[2];
    wire fadd_round = fadd_norm[1];
    wire fadd_sticky = fadd_norm[0];
    wire fadd_inexact = fadd_guard | fadd_round | fadd_sticky;
    wire fadd_round_up =
        (selected_rm == 3'b000) ? (fadd_guard && (fadd_round || fadd_sticky || fadd_retained[0])) :
        (selected_rm == 3'b001) ? 1'b0 :
        (selected_rm == 3'b010) ? (fadd_sign_large && fadd_inexact) :
        (selected_rm == 3'b011) ? (!fadd_sign_large && fadd_inexact) :
        (selected_rm == 3'b100) ? fadd_guard : 1'b0;
    wire [24:0] fadd_rounded = {1'b0,fadd_retained} + {24'd0,fadd_round_up};
    wire [23:0] fadd_sig_final = fadd_rounded[24] ?
                                   fadd_rounded[24:1] : fadd_rounded[23:0];
    wire [8:0] fadd_exp_rounded = fadd_exp_norm + {8'd0,fadd_rounded[24]};


    // Handle cancellation, overflow, packing, and exception flags
    wire fadd_zero_result = ~|fadd_sum_raw;
    wire fadd_zero_sign = (selected_rm == 3'b010) ?
                           (i_frs1[31] | fadd_b_sign) :
                           (i_frs1[31] & fadd_b_sign);
    wire fadd_overflow = fadd_exp_rounded >= 9'd255;
    wire fadd_to_inf = (selected_rm == 3'b000) || (selected_rm == 3'b100) ||
                       ((selected_rm == 3'b010) && fadd_sign_large) ||
                       ((selected_rm == 3'b011) && !fadd_sign_large);
    wire [31:0] fadd_overflow_value = fadd_to_inf ?
        {fadd_sign_large,8'hff,23'd0} :
        {fadd_sign_large,8'hfe,23'h7fffff};
    wire [7:0] fadd_packed_exp = (fadd_exp_rounded == 9'd1 && !fadd_sig_final[23]) ?
                                  8'd0 : fadd_exp_rounded[7:0];
    wire [31:0] fadd_finite_result = fadd_zero_result ?
        {fadd_zero_sign,31'd0} :
        (fadd_overflow ? fadd_overflow_value :
         {fadd_sign_large,fadd_packed_exp,fadd_sig_final[22:0]});
    wire [4:0] fadd_finite_flags =
        {1'b0,1'b0,fadd_overflow,
         ((!fadd_zero_result) && (fadd_packed_exp == 8'd0) && fadd_inexact),
         (fadd_inexact || fadd_overflow)};


    // ---------------------------------------------------------------------
    // Finite FMUL.S datapath
    // ---------------------------------------------------------------------
    // Form and normalize the significand product, adjusting the exponent for operand denormals, product magnitude, and any subnormal result.
    wire fmul_sign = i_frs1[31] ^ i_frs2[31];
    wire [8:0] fmul_exp_sum = {1'b0,(a_exp_zero ? 8'd1 : i_frs1[30:23])} +
                              {1'b0,(b_exp_zero ? 8'd1 : i_frs2[30:23])};
    // product_sum[24] is the exact structural 24x24 product declared above.
    wire [47:0] fmul_product = significand_product;
    wire fmul_top = fmul_product[47];
    wire [8:0] fmul_exp_pre = fmul_exp_sum - 9'd127 + {8'd0,fmul_top};
    wire [47:0] fmul_norm_product = fmul_top ? fmul_product :
                                     {fmul_product[46:0],1'b0};

    // If the unbiased result exponent is below the normal range, shift the exact product right into the subnormal range while retaining sticky
    wire fmul_subnormal = fmul_exp_pre[8] || (fmul_exp_pre == 9'd0);
    wire [8:0] fmul_sub_shift_full = fmul_exp_pre[8] ?
                                      (9'd1 - fmul_exp_pre) :
                                      ((fmul_exp_pre == 9'd0) ? 9'd1 : 9'd0);
    wire [5:0] fmul_sub_shift = (fmul_sub_shift_full > 9'd47) ?
                                 6'd47 : fmul_sub_shift_full[5:0];
    wire [63:0] fmul_shift_input = {fmul_norm_product,16'd0};
    wire [63:0] fmul_shift_1 = fmul_sub_shift[0] ?
        {1'b0,fmul_shift_input[63:2],|fmul_shift_input[1:0]} : fmul_shift_input;
    wire [63:0] fmul_shift_2 = fmul_sub_shift[1] ?
        {2'b0,fmul_shift_1[63:3],|fmul_shift_1[2:0]} : fmul_shift_1;
    wire [63:0] fmul_shift_4 = fmul_sub_shift[2] ?
        {4'b0,fmul_shift_2[63:5],|fmul_shift_2[4:0]} : fmul_shift_2;
    wire [63:0] fmul_shift_8 = fmul_sub_shift[3] ?
        {8'b0,fmul_shift_4[63:9],|fmul_shift_4[8:0]} : fmul_shift_4;
    wire [63:0] fmul_shift_16 = fmul_sub_shift[4] ?
        {16'b0,fmul_shift_8[63:17],|fmul_shift_8[16:0]} : fmul_shift_8;
    wire [63:0] fmul_shifted = fmul_sub_shift[5] ?
        {32'b0,fmul_shift_16[63:33],|fmul_shift_16[32:0]} : fmul_shift_16;

    // Extract rounding bits, round the significand, then update its exponent
    wire [47:0] fmul_round_source = fmul_subnormal ?
                                     fmul_shifted[63:16] : fmul_norm_product;
    wire [23:0] fmul_retained = fmul_round_source[47:24];
    wire fmul_guard = fmul_round_source[23];
    wire fmul_sticky = |fmul_round_source[22:0];
    wire fmul_inexact = fmul_guard | fmul_sticky;
    wire fmul_round_up =
        (selected_rm == 3'b000) ? (fmul_guard && (fmul_sticky || fmul_retained[0])) :
        (selected_rm == 3'b001) ? 1'b0 :
        (selected_rm == 3'b010) ? (fmul_sign && fmul_inexact) :
        (selected_rm == 3'b011) ? (!fmul_sign && fmul_inexact) :
        (selected_rm == 3'b100) ? fmul_guard : 1'b0;
    wire [24:0] fmul_rounded = {1'b0,fmul_retained} + {24'd0,fmul_round_up};
    wire [23:0] fmul_sig_final = fmul_rounded[24] ?
                                  fmul_rounded[24:1] : fmul_rounded[23:0];
    wire [8:0] fmul_exp_after_round = fmul_subnormal ?
        ((fmul_rounded[24] || fmul_sig_final[23]) ? 9'd1 : 9'd0) :
        (fmul_exp_pre + {8'd0,fmul_rounded[24]});


    // Pack the result and select the appropriate overflow value and flags
    wire fmul_overflow = fmul_exp_after_round >= 9'd255;
    wire fmul_to_inf = (selected_rm == 3'b000) || (selected_rm == 3'b100) ||
                       ((selected_rm == 3'b010) && fmul_sign) ||
                       ((selected_rm == 3'b011) && !fmul_sign);
    wire [31:0] fmul_overflow_value = fmul_to_inf ?
        {fmul_sign,8'hff,23'd0} : {fmul_sign,8'hfe,23'h7fffff};
    wire [31:0] fmul_finite_result = fmul_overflow ? fmul_overflow_value :
        {fmul_sign,fmul_exp_after_round[7:0],fmul_sig_final[22:0]};
    wire [4:0] fmul_finite_flags =
        {1'b0,1'b0,fmul_overflow,
         (fmul_subnormal && fmul_inexact),
         (fmul_inexact || fmul_overflow)};


    // ---------------------------------------------------------------------
    // Finite FDIV.S and FSQRT.S datapaths
    // ---------------------------------------------------------------------
    // Normalize subnormal significands with literal-stage shifters
    reg [4:0] norm_lz_a;
    reg [4:0] norm_lz_b;
    always @(*) begin
        casez (sig_a)
            24'b1???????????????????????: norm_lz_a=5'd0;
            24'b01??????????????????????: norm_lz_a=5'd1;
            24'b001?????????????????????: norm_lz_a=5'd2;
            24'b0001????????????????????: norm_lz_a=5'd3;
            24'b00001???????????????????: norm_lz_a=5'd4;
            24'b000001??????????????????: norm_lz_a=5'd5;
            24'b0000001?????????????????: norm_lz_a=5'd6;
            24'b00000001????????????????: norm_lz_a=5'd7;
            24'b000000001???????????????: norm_lz_a=5'd8;
            24'b0000000001??????????????: norm_lz_a=5'd9;
            24'b00000000001?????????????: norm_lz_a=5'd10;
            24'b000000000001????????????: norm_lz_a=5'd11;
            24'b0000000000001???????????: norm_lz_a=5'd12;
            24'b00000000000001??????????: norm_lz_a=5'd13;
            24'b000000000000001?????????: norm_lz_a=5'd14;
            24'b0000000000000001????????: norm_lz_a=5'd15;
            24'b00000000000000001???????: norm_lz_a=5'd16;
            24'b000000000000000001??????: norm_lz_a=5'd17;
            24'b0000000000000000001?????: norm_lz_a=5'd18;
            24'b00000000000000000001????: norm_lz_a=5'd19;
            24'b000000000000000000001???: norm_lz_a=5'd20;
            24'b0000000000000000000001??: norm_lz_a=5'd21;
            24'b00000000000000000000001?: norm_lz_a=5'd22;
            24'b000000000000000000000001: norm_lz_a=5'd23;
            default: norm_lz_a=5'd0;
        endcase
        casez (sig_b)
            24'b1???????????????????????: norm_lz_b=5'd0;
            24'b01??????????????????????: norm_lz_b=5'd1;
            24'b001?????????????????????: norm_lz_b=5'd2;
            24'b0001????????????????????: norm_lz_b=5'd3;
            24'b00001???????????????????: norm_lz_b=5'd4;
            24'b000001??????????????????: norm_lz_b=5'd5;
            24'b0000001?????????????????: norm_lz_b=5'd6;
            24'b00000001????????????????: norm_lz_b=5'd7;
            24'b000000001???????????????: norm_lz_b=5'd8;
            24'b0000000001??????????????: norm_lz_b=5'd9;
            24'b00000000001?????????????: norm_lz_b=5'd10;
            24'b000000000001????????????: norm_lz_b=5'd11;
            24'b0000000000001???????????: norm_lz_b=5'd12;
            24'b00000000000001??????????: norm_lz_b=5'd13;
            24'b000000000000001?????????: norm_lz_b=5'd14;
            24'b0000000000000001????????: norm_lz_b=5'd15;
            24'b00000000000000001???????: norm_lz_b=5'd16;
            24'b000000000000000001??????: norm_lz_b=5'd17;
            24'b0000000000000000001?????: norm_lz_b=5'd18;
            24'b00000000000000000001????: norm_lz_b=5'd19;
            24'b000000000000000000001???: norm_lz_b=5'd20;
            24'b0000000000000000000001??: norm_lz_b=5'd21;
            24'b00000000000000000000001?: norm_lz_b=5'd22;
            24'b000000000000000000000001: norm_lz_b=5'd23;
            default: norm_lz_b=5'd0;
        endcase
    end
    wire [23:0] norm_a_1 = norm_lz_a[0] ? {sig_a[22:0],1'b0} : sig_a;
    wire [23:0] norm_a_2 = norm_lz_a[1] ? {norm_a_1[21:0],2'b0} : norm_a_1;
    wire [23:0] norm_a_4 = norm_lz_a[2] ? {norm_a_2[19:0],4'b0} : norm_a_2;
    wire [23:0] norm_a_8 = norm_lz_a[3] ? {norm_a_4[15:0],8'b0} : norm_a_4;
    wire [23:0] norm_a = norm_lz_a[4] ? {norm_a_8[7:0],16'b0} : norm_a_8;
    wire [23:0] norm_b_1 = norm_lz_b[0] ? {sig_b[22:0],1'b0} : sig_b;
    wire [23:0] norm_b_2 = norm_lz_b[1] ? {norm_b_1[21:0],2'b0} : norm_b_1;
    wire [23:0] norm_b_4 = norm_lz_b[2] ? {norm_b_2[19:0],4'b0} : norm_b_2;
    wire [23:0] norm_b_8 = norm_lz_b[3] ? {norm_b_4[15:0],8'b0} : norm_b_4;
    wire [23:0] norm_b = norm_lz_b[4] ? {norm_b_8[7:0],16'b0} : norm_b_8;

    // Exponents use a +256 internal bias, avoiding signed casts
    wire [10:0] unbiased_a = a_exp_zero ?
        (11'd130 - {6'd0,norm_lz_a}) :
        ({3'd0,i_frs1[30:23]} + 11'd129);
    wire [10:0] unbiased_b = b_exp_zero ?
        (11'd130 - {6'd0,norm_lz_b}) :
        ({3'd0,i_frs2[30:23]} + 11'd129);

    // Restoring division of (normalized numerator * 2^26) by denominator
    wire fdiv_scale_num = norm_a < norm_b;
    wire [23:0] fdiv_num = norm_a;
    wire [49:0] fdiv_dividend = fdiv_scale_num ?
        {fdiv_num,26'd0} : {1'b0,fdiv_num,25'd0};
    wire [24:0] fdiv_rem [50:0];
    wire [49:0] fdiv_qbit;
    assign fdiv_rem[0] = 25'd0;
    genvar dv;
    generate
        for (dv=0; dv<50; dv=dv+1) begin : finite_divider
            wire [24:0] shifted;
            wire ge;
            assign shifted = {fdiv_rem[dv][23:0],fdiv_dividend[49-dv]};
            assign ge = shifted >= {1'b0,norm_b};
            assign fdiv_rem[dv+1] = ge ? (shifted-{1'b0,norm_b}) : shifted;
            assign fdiv_qbit[49-dv] = ge;
        end
    endgenerate

    // Extract quotient and remainder rounding bits, then round the signed result
    wire [26:0] fdiv_q = fdiv_qbit[26:0];
    wire [23:0] fdiv_retained = fdiv_q[25:2];
    wire fdiv_guard = fdiv_q[1];
    wire fdiv_sticky = fdiv_q[0] | (|fdiv_rem[50]);
    wire fdiv_inexact = fdiv_guard | fdiv_sticky;
    wire fdiv_sign = i_frs1[31]^i_frs2[31];
    wire fdiv_round_up =
        (selected_rm==3'b000) ? (fdiv_guard&&(fdiv_sticky||fdiv_retained[0])) :
        (selected_rm==3'b001) ? 1'b0 :
        (selected_rm==3'b010) ? (fdiv_sign&&fdiv_inexact) :
        (selected_rm==3'b011) ? (!fdiv_sign&&fdiv_inexact) :
        (selected_rm==3'b100) ? fdiv_guard : 1'b0;
    wire [24:0] fdiv_rounded = {1'b0,fdiv_retained}+{24'd0,fdiv_round_up};
    wire [23:0] fdiv_sig_final = fdiv_rounded[24] ? fdiv_rounded[24:1] : fdiv_rounded[23:0];
    wire [11:0] fdiv_biased = {1'b0,unbiased_a}-{1'b0,unbiased_b}+
        12'd127-{11'd0,fdiv_scale_num}+{11'd0,fdiv_rounded[24]};
    wire fdiv_overflow = fdiv_biased >= 12'd255;
    wire fdiv_underflow = fdiv_biased[11] || (fdiv_biased == 12'd0);
    wire fdiv_to_inf = (selected_rm==3'b000)||(selected_rm==3'b100)||
        ((selected_rm==3'b010)&&fdiv_sign)||((selected_rm==3'b011)&&!fdiv_sign);
    wire [31:0] fdiv_finite_result = fdiv_overflow ?
        (fdiv_to_inf?{fdiv_sign,8'hff,23'd0}:{fdiv_sign,8'hfe,23'h7fffff}) :
        (fdiv_underflow?{fdiv_sign,31'd0}:{fdiv_sign,fdiv_biased[7:0],fdiv_sig_final[22:0]});
    wire [4:0] fdiv_finite_flags = {1'b0,1'b0,fdiv_overflow,
        (fdiv_underflow&&fdiv_inexact),(fdiv_inexact||fdiv_overflow||fdiv_underflow)};

    // Digit-by-digit square root
    // The radicand is scaled so the 27-bit root contains 24 retained bits plus guard/round/sticky information
    wire sqrt_odd_exp = unbiased_a[0];
    wire [53:0] sqrt_radicand = sqrt_odd_exp ? {norm_a,30'd0} : {1'b0,norm_a,29'd0};
    wire [55:0] sqrt_rem [27:0];
    wire [26:0] sqrt_root [27:0];
    assign sqrt_rem[0]=56'd0;
    assign sqrt_root[0]=27'd0;
    genvar sq;
    generate
        for (sq=0; sq<27; sq=sq+1) begin : finite_sqrt
            wire [55:0] shifted;
            wire [55:0] trial;
            wire ge;
            assign shifted={sqrt_rem[sq][53:0],sqrt_radicand[53-(sq*2)],sqrt_radicand[52-(sq*2)]};
            assign trial={27'd0,sqrt_root[sq],2'b01};
            assign ge=shifted>=trial;
            assign sqrt_rem[sq+1]=ge?(shifted-trial):shifted;
            assign sqrt_root[sq+1]={sqrt_root[sq][25:0],ge};
        end
    endgenerate
    wire [26:0] sqrt_q=sqrt_root[27];
    wire [23:0] sqrt_retained=sqrt_q[26:3];
    wire sqrt_guard=sqrt_q[2];
    wire sqrt_sticky=sqrt_q[1]|sqrt_q[0]|(|sqrt_rem[27]);
    wire sqrt_inexact=sqrt_guard|sqrt_sticky;
    wire sqrt_round_up=(selected_rm==3'b000)?(sqrt_guard&&(sqrt_sticky||sqrt_retained[0])):
        (selected_rm==3'b011)?sqrt_inexact:(selected_rm==3'b100)?sqrt_guard:1'b0;
    wire [24:0] sqrt_rounded={1'b0,sqrt_retained}+{24'd0,sqrt_round_up};
    wire [23:0] sqrt_sig_final=sqrt_rounded[24]?sqrt_rounded[24:1]:sqrt_rounded[23:0];
    // unbiased_a stores the true exponent plus 256
    // floor((unbiased_a - 256) / 2) + 127 = floor(unbiased_a / 2) - 1
    wire [11:0] sqrt_biased={1'b0,unbiased_a[10:1]}-12'd1+
        {11'd0,sqrt_rounded[24]};
    wire [31:0] sqrt_finite_result={1'b0,sqrt_biased[7:0],sqrt_sig_final[22:0]};
    wire [4:0] sqrt_finite_flags={4'b0000,sqrt_inexact};


    // ---------------------------------------------------------------------
    // Finite fused multiply-add datapath and integer conversions
    // ---------------------------------------------------------------------
    // The product remains at full 48-bit precision
    // Operand C is aligned to product before the signed addition, and rounding occurs only once
    wire [23:0] fused_sig_c_raw = {~c_exp_zero,i_frs3[22:0]};
    reg [4:0] fused_lz_c;
    always @(*) begin
        casez (fused_sig_c_raw)
            24'b1???????????????????????: fused_lz_c=5'd0;
            24'b01??????????????????????: fused_lz_c=5'd1;
            24'b001?????????????????????: fused_lz_c=5'd2;
            24'b0001????????????????????: fused_lz_c=5'd3;
            24'b00001???????????????????: fused_lz_c=5'd4;
            24'b000001??????????????????: fused_lz_c=5'd5;
            24'b0000001?????????????????: fused_lz_c=5'd6;
            24'b00000001????????????????: fused_lz_c=5'd7;
            24'b000000001???????????????: fused_lz_c=5'd8;
            24'b0000000001??????????????: fused_lz_c=5'd9;
            24'b00000000001?????????????: fused_lz_c=5'd10;
            24'b000000000001????????????: fused_lz_c=5'd11;
            24'b0000000000001???????????: fused_lz_c=5'd12;
            24'b00000000000001??????????: fused_lz_c=5'd13;
            24'b000000000000001?????????: fused_lz_c=5'd14;
            24'b0000000000000001????????: fused_lz_c=5'd15;
            24'b00000000000000001???????: fused_lz_c=5'd16;
            24'b000000000000000001??????: fused_lz_c=5'd17;
            24'b0000000000000000001?????: fused_lz_c=5'd18;
            24'b00000000000000000001????: fused_lz_c=5'd19;
            24'b000000000000000000001???: fused_lz_c=5'd20;
            24'b0000000000000000000001??: fused_lz_c=5'd21;
            24'b00000000000000000000001?: fused_lz_c=5'd22;
            24'b000000000000000000000001: fused_lz_c=5'd23;
            default: fused_lz_c=5'd0;
        endcase
    end

    wire [23:0] fused_c1=fused_lz_c[0]?{fused_sig_c_raw[22:0],1'b0}:fused_sig_c_raw;
    wire [23:0] fused_c2=fused_lz_c[1]?{fused_c1[21:0],2'b0}:fused_c1;
    wire [23:0] fused_c4=fused_lz_c[2]?{fused_c2[19:0],4'b0}:fused_c2;
    wire [23:0] fused_c8=fused_lz_c[3]?{fused_c4[15:0],8'b0}:fused_c4;
    wire [23:0] fused_sig_c=fused_lz_c[4]?{fused_c8[7:0],16'b0}:fused_c8;
    wire [11:0] fused_exp_c=c_exp_zero?
        (12'd130-{7'd0,fused_lz_c}):
        ({4'd0,i_frs3[30:23]}+12'd129);
    wire fused_prod_top=significand_product[47];
    wire [47:0] fused_prod_norm=fused_prod_top?significand_product:
        {significand_product[46:0],1'b0};
    wire [11:0] fused_exp_prod =
        {1'b0,unbiased_a}+{1'b0,unbiased_b}-12'd256+
        {11'd0,fused_prod_top};
    wire fused_prod_sign=i_frs1[31]^i_frs2[31]^
        ((opcode==OPC_NMSUB)||(opcode==OPC_NMADD));
    wire fused_c_sign=i_frs3[31]^
        ((opcode==OPC_MSUB)||(opcode==OPC_NMADD));
    wire fused_prod_ge_c=(fused_exp_prod>fused_exp_c) ||
        ((fused_exp_prod==fused_exp_c) && ({fused_prod_norm,16'd0}>={fused_sig_c,40'd0}));
    wire [11:0] fused_exp_large=fused_prod_ge_c?fused_exp_prod:fused_exp_c;
    wire [11:0] fused_exp_small=fused_prod_ge_c?fused_exp_c:fused_exp_prod;
    wire [63:0] fused_mag_large=fused_prod_ge_c?{fused_prod_norm,16'd0}:{fused_sig_c,40'd0};
    wire [63:0] fused_mag_small=fused_prod_ge_c?{fused_sig_c,40'd0}:{fused_prod_norm,16'd0};
    wire fused_sign_large=fused_prod_ge_c?fused_prod_sign:fused_c_sign;
    wire fused_sign_small=fused_prod_ge_c?fused_c_sign:fused_prod_sign;
    wire [12:0] fused_diff_full={1'b0,fused_exp_large}-{1'b0,fused_exp_small};
    wire [5:0] fused_diff=(fused_diff_full>13'd63)?6'd63:fused_diff_full[5:0];
    wire [63:0] fused_shift_1=fused_diff[0]?
        {1'b0,fused_mag_small[63:2],|fused_mag_small[1:0]}:fused_mag_small;
    wire [63:0] fused_shift_2=fused_diff[1]?
        {2'b0,fused_shift_1[63:3],|fused_shift_1[2:0]}:fused_shift_1;
    wire [63:0] fused_shift_4=fused_diff[2]?
        {4'b0,fused_shift_2[63:5],|fused_shift_2[4:0]}:fused_shift_2;
    wire [63:0] fused_shift_8=fused_diff[3]?
        {8'b0,fused_shift_4[63:9],|fused_shift_4[8:0]}:fused_shift_4;
    wire [63:0] fused_shift_16=fused_diff[4]?
        {16'b0,fused_shift_8[63:17],|fused_shift_8[16:0]}:fused_shift_8;
    wire [63:0] fused_small_aligned=fused_diff[5]?
        {32'b0,fused_shift_16[63:33],|fused_shift_16[32:0]}:fused_shift_16;
    wire [64:0] fused_sum_ext=(fused_sign_large==fused_sign_small)?
        ({1'b0,fused_mag_large}+{1'b0,fused_small_aligned}):
        ({1'b0,fused_mag_large}-{1'b0,fused_small_aligned});
    wire [63:0] fused_pre_norm=fused_sum_ext[64]?
        {fused_sum_ext[64:2],|fused_sum_ext[1:0]}:fused_sum_ext[63:0];
    wire [12:0] fused_exp_pre=fused_sum_ext[64]?
        ({1'b0,fused_exp_large}+13'd1):{1'b0,fused_exp_large};
    reg [5:0] fused_lz;
    always @(*) begin
        casez (fused_pre_norm)
            64'b1???????????????????????????????????????????????????????????????: fused_lz=6'd0;
            64'b01??????????????????????????????????????????????????????????????: fused_lz=6'd1;
            64'b001?????????????????????????????????????????????????????????????: fused_lz=6'd2;
            64'b0001????????????????????????????????????????????????????????????: fused_lz=6'd3;
            64'b00001???????????????????????????????????????????????????????????: fused_lz=6'd4;
            64'b000001??????????????????????????????????????????????????????????: fused_lz=6'd5;
            64'b0000001?????????????????????????????????????????????????????????: fused_lz=6'd6;
            64'b00000001????????????????????????????????????????????????????????: fused_lz=6'd7;
            64'b000000001???????????????????????????????????????????????????????: fused_lz=6'd8;
            64'b0000000001??????????????????????????????????????????????????????: fused_lz=6'd9;
            64'b00000000001?????????????????????????????????????????????????????: fused_lz=6'd10;
            64'b000000000001????????????????????????????????????????????????????: fused_lz=6'd11;
            64'b0000000000001???????????????????????????????????????????????????: fused_lz=6'd12;
            64'b00000000000001??????????????????????????????????????????????????: fused_lz=6'd13;
            64'b000000000000001?????????????????????????????????????????????????: fused_lz=6'd14;
            64'b0000000000000001????????????????????????????????????????????????: fused_lz=6'd15;
            64'b00000000000000001???????????????????????????????????????????????: fused_lz=6'd16;
            64'b000000000000000001??????????????????????????????????????????????: fused_lz=6'd17;
            64'b0000000000000000001?????????????????????????????????????????????: fused_lz=6'd18;
            64'b00000000000000000001????????????????????????????????????????????: fused_lz=6'd19;
            64'b000000000000000000001???????????????????????????????????????????: fused_lz=6'd20;
            64'b0000000000000000000001??????????????????????????????????????????: fused_lz=6'd21;
            64'b00000000000000000000001?????????????????????????????????????????: fused_lz=6'd22;
            64'b000000000000000000000001????????????????????????????????????????: fused_lz=6'd23;
            64'b0000000000000000000000001???????????????????????????????????????: fused_lz=6'd24;
            64'b00000000000000000000000001??????????????????????????????????????: fused_lz=6'd25;
            64'b000000000000000000000000001?????????????????????????????????????: fused_lz=6'd26;
            64'b0000000000000000000000000001????????????????????????????????????: fused_lz=6'd27;
            64'b00000000000000000000000000001???????????????????????????????????: fused_lz=6'd28;
            64'b000000000000000000000000000001??????????????????????????????????: fused_lz=6'd29;
            64'b0000000000000000000000000000001?????????????????????????????????: fused_lz=6'd30;
            64'b00000000000000000000000000000001????????????????????????????????: fused_lz=6'd31;
            64'b000000000000000000000000000000001???????????????????????????????: fused_lz=6'd32;
            64'b0000000000000000000000000000000001??????????????????????????????: fused_lz=6'd33;
            64'b00000000000000000000000000000000001?????????????????????????????: fused_lz=6'd34;
            64'b000000000000000000000000000000000001????????????????????????????: fused_lz=6'd35;
            64'b0000000000000000000000000000000000001???????????????????????????: fused_lz=6'd36;
            64'b00000000000000000000000000000000000001??????????????????????????: fused_lz=6'd37;
            64'b000000000000000000000000000000000000001?????????????????????????: fused_lz=6'd38;
            64'b0000000000000000000000000000000000000001????????????????????????: fused_lz=6'd39;
            64'b00000000000000000000000000000000000000001???????????????????????: fused_lz=6'd40;
            64'b000000000000000000000000000000000000000001??????????????????????: fused_lz=6'd41;
            64'b0000000000000000000000000000000000000000001?????????????????????: fused_lz=6'd42;
            64'b00000000000000000000000000000000000000000001????????????????????: fused_lz=6'd43;
            64'b000000000000000000000000000000000000000000001???????????????????: fused_lz=6'd44;
            64'b0000000000000000000000000000000000000000000001??????????????????: fused_lz=6'd45;
            64'b00000000000000000000000000000000000000000000001?????????????????: fused_lz=6'd46;
            64'b000000000000000000000000000000000000000000000001????????????????: fused_lz=6'd47;
            64'b0000000000000000000000000000000000000000000000001???????????????: fused_lz=6'd48;
            64'b00000000000000000000000000000000000000000000000001??????????????: fused_lz=6'd49;
            64'b000000000000000000000000000000000000000000000000001?????????????: fused_lz=6'd50;
            64'b0000000000000000000000000000000000000000000000000001????????????: fused_lz=6'd51;
            64'b00000000000000000000000000000000000000000000000000001???????????: fused_lz=6'd52;
            64'b000000000000000000000000000000000000000000000000000001??????????: fused_lz=6'd53;
            64'b0000000000000000000000000000000000000000000000000000001?????????: fused_lz=6'd54;
            64'b00000000000000000000000000000000000000000000000000000001????????: fused_lz=6'd55;
            64'b000000000000000000000000000000000000000000000000000000001???????: fused_lz=6'd56;
            64'b0000000000000000000000000000000000000000000000000000000001??????: fused_lz=6'd57;
            64'b00000000000000000000000000000000000000000000000000000000001?????: fused_lz=6'd58;
            64'b000000000000000000000000000000000000000000000000000000000001????: fused_lz=6'd59;
            64'b0000000000000000000000000000000000000000000000000000000000001???: fused_lz=6'd60;
            64'b00000000000000000000000000000000000000000000000000000000000001??: fused_lz=6'd61;
            64'b000000000000000000000000000000000000000000000000000000000000001?: fused_lz=6'd62;
            64'b0000000000000000000000000000000000000000000000000000000000000001: fused_lz=6'd63;
            default: fused_lz=6'd63;
        endcase
    end
    wire [63:0] fused_n1=fused_lz[0]?{fused_pre_norm[62:0],1'b0}:fused_pre_norm;
    wire [63:0] fused_n2=fused_lz[1]?{fused_n1[61:0],2'b0}:fused_n1;
    wire [63:0] fused_n4=fused_lz[2]?{fused_n2[59:0],4'b0}:fused_n2;
    wire [63:0] fused_n8=fused_lz[3]?{fused_n4[55:0],8'b0}:fused_n4;
    wire [63:0] fused_n16=fused_lz[4]?{fused_n8[47:0],16'b0}:fused_n8;
    wire [63:0] fused_norm=fused_lz[5]?{fused_n16[31:0],32'b0}:fused_n16;
    wire [12:0] fused_exp_norm=fused_exp_pre-{7'd0,fused_lz};
    wire [23:0] fused_keep=fused_norm[63:40];
    wire fused_guard=fused_norm[39];
    wire fused_sticky=|fused_norm[38:0];
    wire fused_inexact=fused_guard|fused_sticky;
    wire fused_round_up=(selected_rm==3'b000)?(fused_guard&&(fused_sticky||fused_keep[0])):
        (selected_rm==3'b001)?1'b0:
        (selected_rm==3'b010)?(fused_sign_large&&fused_inexact):
        (selected_rm==3'b011)?(!fused_sign_large&&fused_inexact):
        (selected_rm==3'b100)?fused_guard:1'b0;
    wire [24:0] fused_rounded={1'b0,fused_keep}+{24'd0,fused_round_up};
    wire [23:0] fused_sig_final=fused_rounded[24]?fused_rounded[24:1]:fused_rounded[23:0];
    wire [13:0] fused_biased={1'b0,fused_exp_norm}-14'd129+
        {13'd0,fused_rounded[24]};
    wire fused_zero=~|fused_sum_ext;
    wire fused_overflow=fused_biased>=14'd255;
    wire fused_underflow=fused_biased[13] || (fused_biased==14'd0);
    wire fused_to_inf=(selected_rm==3'b000)||(selected_rm==3'b100)||
        ((selected_rm==3'b010)&&fused_sign_large)||((selected_rm==3'b011)&&!fused_sign_large);
    wire [31:0] fused_finite_result=fused_zero?{(selected_rm==3'b010),31'd0}:
        (fused_overflow?(fused_to_inf?{fused_sign_large,8'hff,23'd0}:
         {fused_sign_large,8'hfe,23'h7fffff}):
         (fused_underflow?{fused_sign_large,31'd0}:
          {fused_sign_large,fused_biased[7:0],fused_sig_final[22:0]}));
    wire [4:0] fused_finite_flags={1'b0,1'b0,fused_overflow,
        (fused_underflow&&fused_inexact),(fused_inexact||fused_overflow||fused_underflow)};

    // Integer-to-float conversion
    // Signed conversion first forms a magnitude
    wire cvt_i_signed=(rs2_field==5'd0);
    wire cvt_i_neg=cvt_i_signed&&i_xrs1[31];
    wire [31:0] cvt_i_mag=cvt_i_neg?(~i_xrs1+32'd1):i_xrs1;
    reg [4:0] cvt_lz;
    always @(*) begin
        casez (cvt_i_mag)
            32'b1???????????????????????????????: cvt_lz=5'd0;
            32'b01??????????????????????????????: cvt_lz=5'd1;
            32'b001?????????????????????????????: cvt_lz=5'd2;
            32'b0001????????????????????????????: cvt_lz=5'd3;
            32'b00001???????????????????????????: cvt_lz=5'd4;
            32'b000001??????????????????????????: cvt_lz=5'd5;
            32'b0000001?????????????????????????: cvt_lz=5'd6;
            32'b00000001????????????????????????: cvt_lz=5'd7;
            32'b000000001???????????????????????: cvt_lz=5'd8;
            32'b0000000001??????????????????????: cvt_lz=5'd9;
            32'b00000000001?????????????????????: cvt_lz=5'd10;
            32'b000000000001????????????????????: cvt_lz=5'd11;
            32'b0000000000001???????????????????: cvt_lz=5'd12;
            32'b00000000000001??????????????????: cvt_lz=5'd13;
            32'b000000000000001?????????????????: cvt_lz=5'd14;
            32'b0000000000000001????????????????: cvt_lz=5'd15;
            32'b00000000000000001???????????????: cvt_lz=5'd16;
            32'b000000000000000001??????????????: cvt_lz=5'd17;
            32'b0000000000000000001?????????????: cvt_lz=5'd18;
            32'b00000000000000000001????????????: cvt_lz=5'd19;
            32'b000000000000000000001???????????: cvt_lz=5'd20;
            32'b0000000000000000000001??????????: cvt_lz=5'd21;
            32'b00000000000000000000001?????????: cvt_lz=5'd22;
            32'b000000000000000000000001????????: cvt_lz=5'd23;
            32'b0000000000000000000000001???????: cvt_lz=5'd24;
            32'b00000000000000000000000001??????: cvt_lz=5'd25;
            32'b000000000000000000000000001?????: cvt_lz=5'd26;
            32'b0000000000000000000000000001????: cvt_lz=5'd27;
            32'b00000000000000000000000000001???: cvt_lz=5'd28;
            32'b000000000000000000000000000001??: cvt_lz=5'd29;
            32'b0000000000000000000000000000001?: cvt_lz=5'd30;
            32'b00000000000000000000000000000001: cvt_lz=5'd31;
            default: cvt_lz=5'd31;
        endcase
    end
    wire [31:0] cvt_i1=cvt_lz[0]?{cvt_i_mag[30:0],1'b0}:cvt_i_mag;
    wire [31:0] cvt_i2=cvt_lz[1]?{cvt_i1[29:0],2'b0}:cvt_i1;
    wire [31:0] cvt_i4=cvt_lz[2]?{cvt_i2[27:0],4'b0}:cvt_i2;
    wire [31:0] cvt_i8=cvt_lz[3]?{cvt_i4[23:0],8'b0}:cvt_i4;
    wire [31:0] cvt_i_norm=cvt_lz[4]?{cvt_i8[15:0],16'b0}:cvt_i8;
    wire [7:0] cvt_i_exp=8'd158-{3'd0,cvt_lz};
    wire [23:0] cvt_i_keep=cvt_i_norm[31:8];
    wire cvt_i_guard=cvt_i_norm[7];
    wire cvt_i_sticky=|cvt_i_norm[6:0];
    wire cvt_i_inexact=cvt_i_guard|cvt_i_sticky;
    wire cvt_i_round=(selected_rm==3'b000)?(cvt_i_guard&&(cvt_i_sticky||cvt_i_keep[0])):
        (selected_rm==3'b010)?(cvt_i_neg&&cvt_i_inexact):
        (selected_rm==3'b011)?(!cvt_i_neg&&cvt_i_inexact):
        (selected_rm==3'b100)?cvt_i_guard:1'b0;
    wire [24:0] cvt_i_rounded={1'b0,cvt_i_keep}+{24'd0,cvt_i_round};
    wire [31:0] cvt_s_w_result=(cvt_i_mag==32'd0)?32'd0:
        {cvt_i_neg,cvt_i_exp+{7'd0,cvt_i_rounded[24]},
         (cvt_i_rounded[24]?cvt_i_rounded[23:1]:cvt_i_rounded[22:0])};
    wire [4:0] cvt_s_w_flags={4'd0,cvt_i_inexact};

    // Float-to-integer conversion
    wire cvt_w_unsigned=rs2_field[0];

    // Offset by 256: actual shift = exponent-150, encoded as exponent+106.
    wire [11:0] cvt_w_shift={4'd0,i_frs1[30:23]}+12'd106;
    wire cvt_w_shift_negative=(cvt_w_shift<12'd256);
    wire [11:0] cvt_w_shift_magnitude=cvt_w_shift_negative?
        (12'd256-cvt_w_shift):(cvt_w_shift-12'd256);
    wire [63:0] cvt_w_base={40'd0,sig_a};
    wire [5:0] cvt_w_rshift=(cvt_w_shift_magnitude>12'd63)?
        6'd63:cvt_w_shift_magnitude[5:0];
    wire [63:0] cvt_w_right_1=cvt_w_rshift[0]?
        {1'b0,cvt_w_base[63:2],|cvt_w_base[1:0]}:cvt_w_base;
    wire [63:0] cvt_w_right_2=cvt_w_rshift[1]?
        {2'b0,cvt_w_right_1[63:3],|cvt_w_right_1[2:0]}:cvt_w_right_1;
    wire [63:0] cvt_w_right_4=cvt_w_rshift[2]?
        {4'b0,cvt_w_right_2[63:5],|cvt_w_right_2[4:0]}:cvt_w_right_2;
    wire [63:0] cvt_w_right_8=cvt_w_rshift[3]?
        {8'b0,cvt_w_right_4[63:9],|cvt_w_right_4[8:0]}:cvt_w_right_4;
    wire [63:0] cvt_w_right_16=cvt_w_rshift[4]?
        {16'b0,cvt_w_right_8[63:17],|cvt_w_right_8[16:0]}:cvt_w_right_8;
    wire [63:0] cvt_w_shifted_right=cvt_w_rshift[5]?
        {32'b0,cvt_w_right_16[63:33],|cvt_w_right_16[32:0]}:cvt_w_right_16;

    // Literal-stage left barrel shifter
    wire [63:0] cvt_w_left_1 = cvt_w_shift[0] ?
        {cvt_w_base[62:0],1'b0} : cvt_w_base;
    wire [63:0] cvt_w_left_2 = cvt_w_shift[1] ?
        {cvt_w_left_1[61:0],2'b0} : cvt_w_left_1;
    wire [63:0] cvt_w_left_4 = cvt_w_shift[2] ?
        {cvt_w_left_2[59:0],4'b0} : cvt_w_left_2;
    wire [63:0] cvt_w_left_8 = cvt_w_shift[3] ?
        {cvt_w_left_4[55:0],8'b0} : cvt_w_left_4;
    wire [63:0] cvt_w_left_16 = cvt_w_shift[4] ?
        {cvt_w_left_8[47:0],16'b0} : cvt_w_left_8;
    wire [63:0] cvt_w_left_32 = cvt_w_shift[5] ?
        {cvt_w_left_16[31:0],32'b0} : cvt_w_left_16;
    wire [63:0] cvt_w_shifted_left = (cvt_w_shift_magnitude>=12'd40) ?
        64'hffff_ffff_ffff_ffff : cvt_w_left_32;
    wire [63:0] cvt_w_mag=cvt_w_shift_negative?
        cvt_w_shifted_right:cvt_w_shifted_left;
    wire cvt_w_inexact=cvt_w_shift_negative&&cvt_w_shifted_right[0];
    wire cvt_w_invalid=a_nan||a_inf||(cvt_w_unsigned&&i_frs1[31])||
        (!cvt_w_unsigned&&(cvt_w_mag[63:31]!=33'd0))||
        (cvt_w_unsigned&&(cvt_w_mag[63:32]!=32'd0));
    wire [31:0] cvt_w_signed_mag=cvt_w_mag[31:0];
    wire [31:0] cvt_w_signed_value=i_frs1[31]?(~cvt_w_signed_mag+32'd1):cvt_w_signed_mag;
    wire [31:0] cvt_w_result=cvt_w_invalid?
        (cvt_w_unsigned?(i_frs1[31]?32'd0:32'hffff_ffff):
         (i_frs1[31]?32'h8000_0000:32'h7fff_ffff)):
        (cvt_w_unsigned?cvt_w_signed_mag:cvt_w_signed_value);
    wire [4:0] cvt_w_flags={cvt_w_invalid,3'd0,(!cvt_w_invalid&&cvt_w_inexact)};

    // Results and per-instruction flags
    // Arithmetic datapaths use a normalized extended significand
    // Fused path retains the 48-bit product before the addend is aligned, so only the final result is rounded.
    reg [31:0] fp_result_comb;
    reg [31:0] int_result_comb;
    reg [4:0] instruction_flags;
    reg [63:0] work_a;
    reg [63:0] work_b;
    reg [63:0] work_sum;
    reg [8:0] work_exp;
    reg work_sign;
    reg work_guard;
    reg work_sticky;
    reg [24:0] rounded_sig;
    reg [31:0] finite_result;

    // Select results and exception flags for each operation, including special-value handling and the corresponding finite datapaths
    always @(*) begin
        fp_result_comb = 32'd0;
        int_result_comb = 32'd0;
        instruction_flags = 5'd0;
        work_a = 64'd0;
        work_b = 64'd0;
        work_sum = 64'd0;
        work_exp = 9'd0;
        work_sign = 1'b0;
        work_guard = 1'b0;
        work_sticky = 1'b0;
        rounded_sig = 25'd0;
        finite_result = 32'd0;
        case (opcode)
            OPC_SYSTEM: begin
                int_result_comb = csr_old;
            end
            OPC_MADD, OPC_MSUB, OPC_NMSUB, OPC_NMADD: begin
                // The exact fused significand product is retained
                // Special cases are resolved before the finite normalization path
                case ({a_nan|b_nan|c_nan, (a_inf&&b_zero)||(a_zero&&b_inf), a_snan|b_snan|c_snan})
                    3'b001, 3'b011, 3'b101, 3'b111: begin
                        fp_result_comb = CANONICAL_NAN;
                        instruction_flags[4] = 1'b1;
                    end
                    3'b100, 3'b110: fp_result_comb = CANONICAL_NAN;
                    3'b010: begin fp_result_comb = CANONICAL_NAN; instruction_flags[4] = 1'b1; end
                    default: begin
                        // Finite fused datapath result is produced by shared arithmetic sequencer below
                        fp_result_comb = fused_finite_result;
                        instruction_flags = fused_finite_flags;
                    end
                endcase
            end
            OPC_OP_FP: begin
                case (funct7)
                    7'b0010000: begin
                        case (funct3)
                            3'b000: fp_result_comb = {i_frs2[31], i_frs1[30:0]};
                            3'b001: fp_result_comb = {~i_frs2[31], i_frs1[30:0]};
                            default: fp_result_comb = {i_frs1[31]^i_frs2[31], i_frs1[30:0]};
                        endcase
                    end
                    7'b0010100: begin
                        case ({a_nan,b_nan,funct3[0]})
                            3'b110,3'b111: fp_result_comb = CANONICAL_NAN;
                            3'b100,3'b101: fp_result_comb = i_frs2;
                            3'b010,3'b011: fp_result_comb = i_frs1;
                            3'b000: fp_result_comb = fp_less ? i_frs1 : i_frs2;
                            default: fp_result_comb = fp_less ? i_frs2 : i_frs1;
                        endcase
                        instruction_flags[4] = a_snan || b_snan;
                    end
                    7'b1010000: begin
                        case (funct3)
                            3'b010: begin
                                int_result_comb = {31'd0, !(a_nan||b_nan) && fp_equal};
                                instruction_flags[4] = a_snan || b_snan;
                            end
                            3'b001: begin
                                int_result_comb = {31'd0, !(a_nan||b_nan) && fp_less};
                                instruction_flags[4] = a_nan || b_nan;
                            end
                            default: begin
                                int_result_comb = {31'd0, !(a_nan||b_nan) && (fp_less||fp_equal)};
                                instruction_flags[4] = a_nan || b_nan;
                            end
                        endcase
                    end
                    7'b1110000: begin
                        case (funct3)
                            3'b000: int_result_comb = i_frs1;
                            default: int_result_comb = class_result;
                        endcase
                    end
                    7'b1111000: fp_result_comb = i_xrs1;
                    7'b0000000, 7'b0000100: begin
                        // Add/sub special values
                        case ({a_nan|b_nan, a_snan|b_snan,
                               a_inf&&b_inf&&(i_frs1[31]^(i_frs2[31]^(funct7==7'b0000100)))})
                            3'b001,3'b011,3'b101,3'b111: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            3'b100,3'b110: fp_result_comb=CANONICAL_NAN;
                            3'b010: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            default: fp_result_comb = a_inf ? i_frs1 :
                                (b_inf ? {i_frs2[31]^(funct7==7'b0000100),i_frs2[30:0]} :
                                 fadd_finite_result);
                        endcase
                        case ({a_nan|b_nan,a_inf|b_inf,funct7})
                            {2'b00,7'b0000000},
                            {2'b00,7'b0000100}: instruction_flags = fadd_finite_flags;
                            default: instruction_flags = instruction_flags;
                        endcase
                    end
                    7'b0001000: begin
                        case ({a_nan|b_nan, a_snan|b_snan, (a_inf&&b_zero)||(a_zero&&b_inf)})
                            3'b001,3'b011,3'b101,3'b111: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            3'b100,3'b110: fp_result_comb=CANONICAL_NAN;
                            3'b010: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            default: fp_result_comb = (a_inf||b_inf) ? {i_frs1[31]^i_frs2[31],8'hff,23'd0} :
                                ((a_zero||b_zero) ? {i_frs1[31]^i_frs2[31],31'd0} : fmul_finite_result);
                        endcase
                        case ({a_nan|b_nan,a_inf|b_inf,a_zero|b_zero})
                            3'b000: instruction_flags = fmul_finite_flags;
                            default: instruction_flags = instruction_flags;
                        endcase
                    end
                    7'b0001100: begin
                        case ({a_nan|b_nan,a_snan|b_snan,(a_zero&&b_zero)||(a_inf&&b_inf),b_zero})
                            4'b0001: begin
                                fp_result_comb={i_frs1[31]^i_frs2[31],8'hff,23'd0};
                                instruction_flags[3]=!a_zero&&!a_inf;
                            end
                            4'b0010,4'b0011: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            4'b0100,4'b0101,4'b0110,4'b0111: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            4'b1000,4'b1001,4'b1010,4'b1011: fp_result_comb=CANONICAL_NAN;
                            default: fp_result_comb = a_inf ? {i_frs1[31]^i_frs2[31],8'hff,23'd0} :
                                (b_inf ? {i_frs1[31]^i_frs2[31],31'd0} : fdiv_finite_result);
                        endcase
                        case ({a_nan|b_nan,a_inf|b_inf,a_zero|b_zero})
                            3'b000: instruction_flags=fdiv_finite_flags;
                            default: instruction_flags=instruction_flags;
                        endcase
                    end
                    7'b0101100: begin
                        case ({a_nan,a_snan,i_frs1[31],a_zero})
                            4'b0100,4'b0101,4'b0110,4'b0111: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            4'b1000,4'b1001,4'b1010,4'b1011: fp_result_comb=CANONICAL_NAN;
                            4'b0010: begin fp_result_comb=CANONICAL_NAN; instruction_flags[4]=1'b1; end
                            default: fp_result_comb = a_zero ? i_frs1 : sqrt_finite_result;
                        endcase
                        case ({a_nan,a_inf,i_frs1[31],a_zero})
                            4'b0000: instruction_flags=sqrt_finite_flags;
                            default: instruction_flags=instruction_flags;
                        endcase
                    end
                    7'b1100000: begin
                        // Float-to-integer saturation and exact common cases
                        case ({a_nan,a_inf,i_frs1[31],rs2_field[0]})
                            4'b1000,4'b1010,4'b0100: begin int_result_comb=32'h7fff_ffff; instruction_flags[4]=1'b1; end
                            4'b1001,4'b0101: begin int_result_comb=32'hffff_ffff; instruction_flags[4]=1'b1; end
                            4'b0110: begin int_result_comb=32'h8000_0000; instruction_flags[4]=1'b1; end
                            4'b0011: begin int_result_comb=32'd0; instruction_flags[4]=1'b1; end
                            default: begin
                                int_result_comb = cvt_w_result;
                                instruction_flags = cvt_w_flags;
                            end
                        endcase
                    end
                    7'b1101000: begin
                        fp_result_comb = cvt_s_w_result;
                        instruction_flags = cvt_s_w_flags;
                    end
                    default: begin fp_result_comb=32'd0; int_result_comb=32'd0; end
                endcase
            end
            default: begin fp_result_comb=32'd0; int_result_comb=32'd0; end
        endcase
    end

    // Multi-cycle arithmetic controller
    // Serializes all rounding arithmetic
    // Result registers hold until i_advance.
    localparam [1:0] ST_IDLE=2'd0, ST_RUN=2'd1, ST_DONE=2'd2;
    reg [1:0] state;
    reg [5:0] count;
    reg [31:0] held_fp_result;
    reg [31:0] held_int_result;
    reg [4:0] held_flags;
    wire long_operation = i_valid && instruction_rounds && !is_csr;
    wire [5:0] count_next = count + 6'd1;

    // Uses the structural product above and deterministic rounding fallback
    // The datapath is held for 32 cycles to satisfy EX stall protocol
    always @(posedge i_clk) begin
        if (i_rst) begin
            state <= ST_IDLE;
            count <= 6'd0;
            held_fp_result <= 32'd0;
            held_int_result <= 32'd0;
            held_flags <= 5'd0;
            accrued_flags <= 5'd0;
            frm <= 3'd0;
        end else begin
            if (state == ST_IDLE) begin
                if (long_operation && !o_rm_trap) begin
                    state <= ST_RUN;
                    count <= 6'd0;
                end else if (i_valid && i_advance) begin
                    if (is_csr) begin
                        if (csr_write_en) begin
                            case (csr_addr)
                                12'h001: accrued_flags <= csr_new[4:0];
                                12'h002: frm <= csr_new[2:0];
                                12'h003: begin accrued_flags <= csr_new[4:0]; frm <= csr_new[7:5]; end
                                default: begin accrued_flags <= accrued_flags; frm <= frm; end
                            endcase
                        end
                    end else begin
                        accrued_flags <= accrued_flags | instruction_flags;
                    end
                end
            end else if (state == ST_RUN) begin
                count <= count_next;
                if (count == 6'd31) begin
                    held_fp_result <= fp_result_comb;
                    held_int_result <= int_result_comb;
                    held_flags <= instruction_flags;
                    state <= ST_DONE;
                end
            end else if (state == ST_DONE) begin
                if (i_advance) begin
                    accrued_flags <= accrued_flags | held_flags;
                    state <= ST_IDLE;
                end
            end else begin
                state <= ST_IDLE;
            end
        end
    end

    assign o_busy = i_valid && long_operation && !o_rm_trap && (state != ST_DONE);
    assign o_fp_result = (state == ST_DONE) ? held_fp_result : fp_result_comb;
    assign o_int_result = (state == ST_DONE) ? held_int_result : int_result_comb;
    assign o_fflags = accrued_flags |
        ((state == ST_DONE) ? held_flags : (i_valid && !is_csr ? instruction_flags : 5'd0));

endmodule
`default_nettype wire
