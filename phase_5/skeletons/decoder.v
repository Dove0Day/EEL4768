`default_nettype none

// Remember to instantiate the imm in this module

module decoder (
    // Input instruction word.
    input  wire [31:0] i_inst,
    // Asserted if the instruction was decoded as a legal instruction. It is
    // important that the decoder not accept any illegal instruction
    // encodings as this could lead to undefined behavior in the processor
    // which is a safety hazard.
    output wire        o_legal,
    // Indicates that the instruction is an ebreak and should halt execution.
    output wire        o_halt,
    // First source register address.
    // For instructions that do not use a source register, this is effectively
    // a don't care because reading unused registers does not have any side
    // effects (and we don't care about power usage, really).
    output wire [ 4:0] o_rs1,
    // Second source register address.
    // Similarly to o_rs1, this is a don't care for instructions that do not
    // read a (second) source register.
    output wire [ 4:0] o_rs2,
    // Destination register address.
    // For instructions that do not write to a register, this must be set to
    // x0 so the value is discarded. This avoids the need for a separate write
    // enable since discard behavior must be present anyway.
    output wire [ 4:0] o_rd,
    // 32-bit immediate value, decoded from the instruction word. For R-type
    // instructions that do not use an immediate, this is a don't care.
    output wire [31:0] o_immediate,
    // Selects whether the first operand for the ALU is fed by the first
    // register source (rs1) or the current pc.
    // When asserted, the second operand is the immediate.
    output wire        o_op1_sel,
    // Selects whether the second operand for the ALU is fed by the second
    // register source (rs2) or the immediate.
    // When asserted, the second operand is the immediate.
    output wire        o_op2_sel,
    // Major opsel for the ALU. See ALU documentation for the encoding.
    output wire [ 2:0] o_alu_opsel,
    // Minor opsel flags for the ALU. See ALU documentation for the encoding.
    output wire        o_alu_sub,
    output wire        o_alu_unsigned,
    output wire        o_alu_arith,
    // If asserted, the instruction is a branch instruction and the PC should
    // be updated to the target address if the branch condition is met.
    output wire        o_branch,
    // If asserted, the instruction is a jump instruction and the PC should
    // be updated to the target address unconditionally.
    output wire        o_jump,
    // When asserted, the branch comparator checks for equality. When not
    // asserted, it checks for less than [unsigned].
    output wire        o_branch_equal,
    // When asserted, the branch comparator treats the less than comparison
    // operands as unsigned. This is only used when `!o_branch_equal`.
    output wire        o_branch_unsigned,
    // When asserted, the branch condition is inverted.
    // Equality -> inequality, less than -> greater than or equal.
    output wire        o_branch_invert,
    // When asserted, the instruction will load from memory.
    output wire        o_dmem_ren,
    // When asserted, the instruction will store to memory.
    output wire        o_dmem_wen,
    // This 2-bit mask selects which LSBs of the memory address should be
    // checked for alignment. This is because byte and half-word accesses need
    // only be 1-byte and 2-byte aligned, respectively.
    output wire [ 1:0] o_dmem_align,
    // These 3 bits select the size of the memory access.
    // They are effectively one-hot encoded.
    output wire        o_dmem_memb,
    output wire        o_dmem_memh,
    output wire        o_dmem_memw,
    // If asserted, the (byte or half-word) memory access is unsigned and the
    // load should be zero-extended to 32 bits instead of sign-extended.
    output wire        o_dmem_memu,
    // Selects the data to write to the destination register, one-hot.
    // [0] = ALU result
    // [1] = immediate
    // [2] = PC + 4
    // [3] = memory
    output wire [ 3:0] o_rd_sel,
    // If asserted, the PC jumps to the target address calculated by the ALU
    // rather than directly to the PC + immediate. This is used for JALR.
    output wire        o_pc_sel
);
    // Your implementation goes under here
    // ------------------------------------

    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;

    wire [4:0] rs1;
    wire [4:0] rs2;
    wire [4:0] rd;

    // Extract instruction fields
    // R-type: funct3, funct7 -> operation
    // I (default): funct3 -> operation, funct7 -> shift variant
    // S/I (load): funct3 -> sign/size
    // B: funct3 -> comparison variant
    assign opcode = i_inst[6:0];
    assign rd     = i_inst[11:7];
    assign funct3 = i_inst[14:12];
    assign rs1    = i_inst[19:15];
    assign rs2    = i_inst[24:20];
    assign funct7 = i_inst[31:25];

    // opcodes
    localparam [6:0] OPC_LOAD   = 7'b0000011;
    localparam [6:0] OPC_OPIMM  = 7'b0010011;
    localparam [6:0] OPC_AUIPC  = 7'b0010111;
    localparam [6:0] OPC_STORE  = 7'b0100011;
    localparam [6:0] OPC_OP     = 7'b0110011;
    localparam [6:0] OPC_LUI    = 7'b0110111;
    localparam [6:0] OPC_BRANCH = 7'b1100011;
    localparam [6:0] OPC_JALR   = 7'b1100111;
    localparam [6:0] OPC_JAL    = 7'b1101111;
    localparam [6:0] OPC_SYSTEM = 7'b1110011;

    // Legality checks

    // R
    // default: funct7 -> 0000000
    // sub, sra:       -> 0100000
    wire valid_op;
    assign valid_op =
        (opcode == OPC_OP) &&
        (
            ((funct7 == 7'b0000000) &&
             ((funct3 == 3'b000) ||
              (funct3 == 3'b001) ||
              (funct3 == 3'b010) ||
              (funct3 == 3'b011) ||
              (funct3 == 3'b100) ||
              (funct3 == 3'b101) ||
              (funct3 == 3'b110) ||
              (funct3 == 3'b111))) ||
            ((funct7 == 7'b0100000) &&
             ((funct3 == 3'b000) ||
              (funct3 == 3'b101)))
        );

    // I (default)
    // Only shift-immediate restrict funct7
    // slli, srli: funct7 -> 0000000
    // srai:              -> 0100000
    wire valid_opimm;
    assign valid_opimm =
        (opcode == OPC_OPIMM) &&
        (
            (funct3 == 3'b000) || // ADDI
            (funct3 == 3'b010) || // SLTI
            (funct3 == 3'b011) || // SLTIU
            (funct3 == 3'b100) || // XORI
            (funct3 == 3'b110) || // ORI
            (funct3 == 3'b111) || // ANDI
            ((funct3 == 3'b001) &&
             (funct7 == 7'b0000000)) || // SLLI
            ((funct3 == 3'b101) &&
             ((funct7 == 7'b0000000) ||
              (funct7 == 7'b0100000)))   // SRLI/SRAI
        );

    // I (load)
    // lb: funct3 -> 000
    // lh:           001
    // lw:           010
    // lbu:          100
    // lhu:          101
    wire valid_load;
    assign valid_load =
        (opcode == OPC_LOAD) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b010) ||
            (funct3 == 3'b100) ||
            (funct3 == 3'b101)
        );

    // S
    // sb: funct3 -> 000
    // sh:           001
    // sw:           010
    wire valid_store;
    assign valid_store =
        (opcode == OPC_STORE) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b010)
        );

    // B 
    // beq, bne, blt, bge, bltu, bgeu
    wire valid_branch;
    assign valid_branch =
        (opcode == OPC_BRANCH) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b100) ||
            (funct3 == 3'b101) ||
            (funct3 == 3'b110) ||
            (funct3 == 3'b111)
        );

    wire valid_jalr;
    assign valid_jalr =
        (opcode == OPC_JALR) &&
        (funct3 == 3'b000);

    wire valid_jal;
    assign valid_jal = (opcode == OPC_JAL);

    wire valid_lui;
    assign valid_lui = (opcode == OPC_LUI);

    wire valid_auipc;
    assign valid_auipc = (opcode == OPC_AUIPC);

    wire valid_ebreak;
    assign valid_ebreak = (i_inst == 32'h00100073);

    assign o_legal =
        valid_op      ||
        valid_opimm   ||
        valid_load    ||
        valid_store   ||
        valid_branch  ||
        valid_jalr    ||
        valid_jal     ||
        valid_lui     ||
        valid_auipc   ||
        valid_ebreak;

    assign o_halt = valid_ebreak;

    // Registers
    assign o_rs1 =
        (valid_op ||
        valid_opimm ||
        valid_load ||
        valid_store ||
        valid_branch ||
        valid_jalr) ? rs1 : 5'd0;

    assign o_rs2 =
        (valid_op ||
        valid_store ||
        valid_branch) ? rs2 : 5'd0;

    assign o_rd =
        (valid_op    ||
         valid_opimm ||
         valid_load  ||
         valid_jalr  ||
         valid_jal   ||
         valid_lui   ||
         valid_auipc) ? rd : 5'd0;

    // Immediate format
    // bit 0: R -> none
    // bit 1: I
    // bit 2: S
    // bit 3: B
    // bit 4: U
    // bit 5: J
    wire [5:0] imm_format;

    assign imm_format =
        valid_op                         ? 6'b000001 :
        (valid_opimm || valid_load ||
         valid_jalr)                     ? 6'b000010 :
        valid_store                      ? 6'b000100 :
        valid_branch                     ? 6'b001000 :
        (valid_lui || valid_auipc)       ? 6'b010000 :
        valid_jal                        ? 6'b100000 :
                                           6'b000000;

    imm u_imm (
        .i_inst      (i_inst),
        .i_format    (imm_format),
        .o_immediate (o_immediate)
    );

    // Operand 1
    // general: rs1
    // auipc: pc
    assign o_op1_sel = valid_auipc;

    // Operand 2
    // R/B: rs2
    // Immediate -> assert
    assign o_op2_sel =
        valid_opimm ||
        valid_load  ||
        valid_store ||
        valid_auipc ||
        valid_jalr;

    assign o_alu_opsel =
        (valid_op || valid_opimm) ? funct3 :
        (valid_branch && funct3[1]) ? 3'b011 :
                                    3'b000;


    // add: funct7 -> 0000000
    // sub:        -> 0100000
    assign o_alu_sub =
        valid_op &&
        (funct3 == 3'b000) &&
        (funct7 == 7'b0100000);

    // sltu, sltiu, bltu, bgeu
    assign o_alu_unsigned =
        (valid_op &&
         (funct3 == 3'b011)) ||
        (valid_opimm &&
         (funct3 == 3'b011)) ||
        (valid_branch &&
         funct3[1]);

    // sra, srai
    assign o_alu_arith =
        (valid_op || valid_opimm) &&
        (funct3 == 3'b101) &&
        (funct7 == 7'b0100000);

    // B
    // beq: funct3 -> 000
    // bne:           001
    // blt:           100
    // bge:           101
    // bltu:          110
    // bgeu:          111
    assign o_branch = valid_branch;
    assign o_jump   = valid_jal || valid_jalr;

    assign o_branch_equal =
        valid_branch && !funct3[2];

    assign o_branch_unsigned =
        valid_branch && funct3[1];

    assign o_branch_invert =
        valid_branch && funct3[0];

    // jalr
    // rs1: jump target base
    assign o_pc_sel = valid_jalr;

    // funct3[1:0] -> access width
    // 00: byte
    // 01: half-word
    // 10: word
    assign o_dmem_ren = valid_load;
    assign o_dmem_wen = valid_store;

    assign o_dmem_memb =
        (valid_load || valid_store) &&
        (funct3[1:0] == 2'b00);

    assign o_dmem_memh =
        (valid_load || valid_store) &&
        (funct3[1:0] == 2'b01);

    assign o_dmem_memw =
        (valid_load || valid_store) &&
        (funct3[1:0] == 2'b10);

    // Alignment masks
    // 00: no restriction
    // 01: bit 0 = 0
    // 11: bits 1:0 = 0
    assign o_dmem_align =
        o_dmem_memw ? 2'b11 :
        o_dmem_memh ? 2'b01 :
                       2'b00;

    // lbu, lhu = unsigned loads
    assign o_dmem_memu =
        valid_load &&
        ((funct3 == 3'b100) ||
         (funct3 == 3'b101));

    // Register writeback select
    // 0: alu
    // 1: imm
    // 2: pc + 4
    // 3: mem
    assign o_rd_sel =
        (valid_op ||
         valid_opimm ||
         valid_auipc) ? 4'b0001 :
        valid_lui     ? 4'b0010 :
        (valid_jal ||
         valid_jalr)  ? 4'b0100 :
        valid_load    ? 4'b1000 :
                        4'b0000;

endmodule

`default_nettype wire