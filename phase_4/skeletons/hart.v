`default_nettype none

module hart #(
    // After reset, the program counter (PC) should be initialized to this
    // address and start executing instructions from there.
    parameter RESET_ADDR = 32'h00400000,
    // When set, pipeline forwarding optimizations are enabled.
    parameter FWD_EN = 1,
    // When set, register file bypassing is enabled.
    parameter BYPASS_EN = 1
) (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Instruction fetch goes through a read only instruction memory (imem)
    // port. The port accepts a 32-bit address (e.g. from the program counter)
    // per cycle and combinationally returns a 32-bit instruction word. This
    // is not representative of a realistic memory interface; it has been
    // modeled as more similar to a DFF or SRAM to simplify phase 3. In
    // later phases, you will replace this with a more realistic memory.
    //
    // 32-bit read address for the instruction memory. This is expected to be
    // 4 byte aligned - that is, the two LSBs should be zero.
    output wire [31:0] o_imem_raddr,
    // Instruction word fetched from memory, available on the same cycle.
    input  wire [31:0] i_imem_rdata,
    // Data memory accesses go through a separate read/write data memory (dmem)
    // that is shared between read (load) and write (stored). The port accepts
    // a 32-bit address, read or write enable, and mask (explained below) each
    // cycle. Reads are combinational - values are available immediately after
    // updating the address and asserting read enable. Writes occur on (and
    // are visible at) the next clock edge.
    //
    // Read/write address for the data memory. This should be 32-bit aligned
    // (i.e. the two LSB should be zero). See `o_dmem_mask` for how to perform
    // half-word and byte accesses at unaligned addresses.
    output wire [31:0] o_dmem_addr,
    // When asserted, the memory will perform a read at the aligned address
    // specified by `i_addr` and return the 32-bit word at that address
    // immediately (i.e. combinationally). It is illegal to assert this and
    // `o_dmem_wen` on the same cycle.
    output wire        o_dmem_ren,
    // When asserted, the memory will perform a write to the aligned address
    // `o_dmem_addr`. When asserted, the memory will write the bytes in
    // `o_dmem_wdata` (specified by the mask) to memory at the specified
    // address on the next rising clock edge. It is illegal to assert this and
    // `o_dmem_ren` on the same cycle.
    output wire        o_dmem_wen,
    // The 32-bit word to write to memory when `o_dmem_wen` is asserted. When
    // write enable is asserted, the byte lanes specified by the mask will be
    // written to the memory word at the aligned address at the next rising
    // clock edge. The other byte lanes of the word will be unaffected.
    output wire [31:0] o_dmem_wdata,
    // The dmem interface expects word (32 bit) aligned addresses. However,
    // WISC-25 supports byte and half-word loads and stores at unaligned and
    // 16-bit aligned addresses, respectively. To support this, the access
    // mask specifies which bytes within the 32-bit word are actually read
    // from or written to memory.
    //
    // To perform a half-word read at address 0x00001002, align `o_dmem_addr`
    // to 0x00001000, assert `o_dmem_ren`, and set the mask to 0b1100 to
    // indicate that only the upper two bytes should be read. Only the upper
    // two bytes of `i_dmem_rdata` can be assumed to have valid data; to
    // calculate the final value of the `lh[u]` instruction, shift the rdata
    // word right by 16 bits and sign/zero extend as appropriate.
    //
    // To perform a byte write at address 0x00002003, align `o_dmem_addr` to
    // `0x00002003`, assert `o_dmem_wen`, and set the mask to 0b1000 to
    // indicate that only the upper byte should be written. On the next clock
    // cycle, the upper byte of `o_dmem_wdata` will be written to memory, with
    // the other three bytes of the aligned word unaffected. Remember to shift
    // the value of the `sb` instruction left by 24 bits to place it in the
    // appropriate byte lane.
    output wire [ 3:0] o_dmem_mask,
    // The 32-bit word read from data memory. When `o_dmem_ren` is asserted,
    // this will immediately reflect the contents of memory at the specified
    // address, for the bytes enabled by the mask. When read enable is not
    // asserted, or for bytes not set in the mask, the value is undefined.
    input  wire [31:0] i_dmem_rdata,
    // The output `retire` interface is used to signal to the testbench that
    // the CPU has completed and retired an instruction. A single cycle
    // implementation will assert this every cycle; however, a pipelined
    // implementation that needs to stall (due to internal hazards or waiting
    // on memory accesses) will not assert the signal on cycles where the
    // instruction in the writeback stage is not retiring.
    //
    // Asserted when an instruction is being retired this cycle. If this is
    // not asserted, the other retire signals are ignored and may be left invalid.
    output wire        o_retire_valid,
    // The 32 bit instruction word of the instrution being retired. This
    // should be the unmodified instruction word fetched from instruction
    // memory.
    output wire [31:0] o_retire_inst,
    // Asserted if the instruction produced a trap, due to an illegal
    // instruction, unaligned data memory access, or unaligned instruction
    // address on a taken branch or jump.
    output wire        o_retire_trap,
    // Asserted if the instruction is an `ebreak` instruction used to halt the
    // processor. This is used for debugging and testing purposes to end
    // a program.
    output wire        o_retire_halt,
    // The first register address read by the instruction being retired. If
    // the instruction does not read from a register (like `lui`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs1_raddr,
    // The second register address read by the instruction being retired. If
    // the instruction does not read from a second register (like `addi`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs2_raddr,
    // The first source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs1 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs1_rdata,
    // The second source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs2 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs2_rdata,
    // The destination register address written by the instruction being
    // retired. If the instruction does not write to a register (like `sw`),
    // this should be 5'd0.
    output wire [ 4:0] o_retire_rd_waddr,
    // The destination register data written to the register file in the
    // writeback stage by this instruction. If rd is 5'd0, this field is
    // ignored and can be treated as a don't care.
    output wire [31:0] o_retire_rd_wdata,
    output wire [31:0] o_retire_dmem_addr,
    output wire [ 3:0] o_retire_dmem_mask,
    output wire        o_retire_dmem_ren,
    output wire        o_retire_dmem_wen,
    output wire [31:0] o_retire_dmem_rdata,
    output wire [31:0] o_retire_dmem_wdata,
    // The current program counter of the instruction being retired - i.e.
    // the instruction memory address that the instruction was fetched from.
    output wire [31:0] o_retire_pc,
    // the next program counter after the instruction is retired. For most
    // instructions, this is `o_retire_pc + 4`, but must be the branch or jump
    // target for *taken* branches and jumps.
    output wire [31:0] o_retire_next_pc

`ifdef RISCV_FORMAL
    ,`RVFI_OUTPUTS,
`endif
);

    //Default NOP instruction word
    localparam [31:0] NOP = 32'h00000013;

    // IF stage

    // PC Register and fetching
    reg  [31:0] pc; // program counter
    reg         stop_fetch; //flag to freeze PC fetch
    wire [31:0] pc_plus4; // address of next instruction

    assign pc_plus4     = pc + 32'd4;
    assign o_imem_raddr = pc; // instruction memory address

    // IF/ID pipeline registers

    reg         ifid_valid;
    reg  [31:0] ifid_inst;
    reg  [31:0] ifid_pc;

    // ID stage: decoder and register file

    wire        dec_legal; // high if instruction encoding is valid
    wire        dec_halt; // high if decoder requests a halt

    // decode and register read
    // source and destination register addresses
    wire [4:0]  dec_rs1;
    wire [4:0]  dec_rs2;
    wire [4:0]  dec_rd;

    wire [31:0] dec_imm; //extracted sign-extended immediate

    wire        dec_op1_sel; // selects alu input 1
    wire        dec_op2_sel; // selects alu input 2

    //selects alu operation and gives instructions
    wire [2:0]  dec_alu_opsel;
    wire        dec_alu_sub;
    wire        dec_alu_unsigned;
    wire        dec_alu_arith;

    wire        dec_branch; // high if its a branch instruction
    wire        dec_jump; //high if its a jump
    wire        dec_branch_equal;
    wire        dec_branch_unsigned;
    wire        dec_branch_invert;

    wire        dec_dmem_ren; // memory read enable
    wire        dec_dmem_wen; // memory write enable
    wire [1:0]  dec_dmem_align; // memory access alignment
    wire        dec_dmem_memb; // byte wide access
    wire        dec_dmem_memh; // half word access
    wire        dec_dmem_memw; // word wide access
    wire        dec_dmem_memu; // unsigned load flag

    wire [3:0]  dec_rd_sel; // writeback data source
    wire        dec_pc_sel; // selects jump target

    // decoder module turns the instruction into control signals
    decoder decoder_inst (
        .i_inst            (ifid_inst),

        .o_legal           (dec_legal),
        .o_halt            (dec_halt),

        .o_rs1             (dec_rs1),
        .o_rs2             (dec_rs2),
        .o_rd              (dec_rd),
        .o_immediate       (dec_imm),

        .o_op1_sel         (dec_op1_sel),
        .o_op2_sel         (dec_op2_sel),

        .o_alu_opsel       (dec_alu_opsel),
        .o_alu_sub         (dec_alu_sub),
        .o_alu_unsigned    (dec_alu_unsigned),
        .o_alu_arith       (dec_alu_arith),

        .o_branch          (dec_branch),
        .o_jump            (dec_jump),
        .o_branch_equal    (dec_branch_equal),
        .o_branch_unsigned (dec_branch_unsigned),
        .o_branch_invert   (dec_branch_invert),

        .o_dmem_ren        (dec_dmem_ren),
        .o_dmem_wen        (dec_dmem_wen),
        .o_dmem_align      (dec_dmem_align),
        .o_dmem_memb       (dec_dmem_memb),
        .o_dmem_memh       (dec_dmem_memh),
        .o_dmem_memw       (dec_dmem_memw),
        .o_dmem_memu       (dec_dmem_memu),

        .o_rd_sel          (dec_rd_sel),
        .o_pc_sel          (dec_pc_sel)
    );

    // illegal instructions report no source-register reads
    wire [4:0] id_rs1_addr;
    wire [4:0] id_rs2_addr;
    wire       id_halt;

    assign id_rs1_addr = (ifid_valid && dec_legal) ? dec_rs1 : 5'd0;
    assign id_rs2_addr = (ifid_valid && dec_legal) ? dec_rs2 : 5'd0;
    assign id_halt     = ifid_valid && dec_halt;

    // register file
    // data outputs from source registers
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;

    // writeback signals feed the register file
    reg  [4:0]  memwb_rd_waddr;
    reg  [31:0] memwb_rd_wdata;
    reg         memwb_valid;
    reg         memwb_regwrite;

    wire [4:0] rf_waddr; // destination register write address
    assign rf_waddr =
        (memwb_valid && memwb_regwrite) ? memwb_rd_waddr : 5'd0;

    // register file instance
    rf #(
        .BYPASS_EN(BYPASS_EN)
    ) rf_inst (
        .i_clk       (i_clk),
        .i_rst       (i_rst),

        .i_rs1_raddr (id_rs1_addr),
        .o_rs1_rdata (rf_rs1_data),

        .i_rs2_raddr (id_rs2_addr),
        .o_rs2_rdata (rf_rs2_data),

        .i_rd_waddr  (rf_waddr),
        .i_rd_wdata  (memwb_rd_wdata)
    );

    // ID/EX pipeline registers

    reg         idex_valid;
    reg  [31:0] idex_inst;
    reg  [31:0] idex_pc;
    reg  [31:0] idex_pc4;

    reg  [4:0]  idex_rs1_addr;
    reg  [4:0]  idex_rs2_addr;
    reg  [4:0]  idex_rd_addr;
    reg  [31:0] idex_rs1_data;
    reg  [31:0] idex_rs2_data;
    reg  [31:0] idex_imm;

    reg         idex_legal;
    reg         idex_halt;
    reg         idex_op1_sel;
    reg         idex_op2_sel;
    reg  [2:0]  idex_alu_opsel;
    reg         idex_alu_sub;
    reg         idex_alu_unsigned;
    reg         idex_alu_arith;

    reg         idex_branch;
    reg         idex_jump;
    reg         idex_branch_equal;
    reg         idex_branch_unsigned;
    reg         idex_branch_invert;
    reg         idex_pc_sel;

    reg         idex_dmem_ren;
    reg         idex_dmem_wen;
    reg         idex_dmem_memb;
    reg         idex_dmem_memh;
    reg         idex_dmem_memw;
    reg         idex_dmem_memu;
    reg  [3:0]  idex_rd_sel;

    // EX/MEM pipeline registers

    reg         exmem_valid;
    reg  [31:0] exmem_inst;
    reg  [31:0] exmem_pc;
    reg  [31:0] exmem_next_pc;

    reg  [4:0]  exmem_rs1_addr;
    reg  [4:0]  exmem_rs2_addr;
    reg  [31:0] exmem_rs1_data;
    reg  [31:0] exmem_rs2_data;

    reg  [4:0]  exmem_rd_addr;
    reg  [31:0] exmem_alu_result;
    reg  [31:0] exmem_imm;
    reg  [31:0] exmem_pc4;

    reg         exmem_trap;
    reg         exmem_halt;
    reg         exmem_regwrite;
    reg  [3:0]  exmem_rd_sel;

    reg         exmem_dmem_ren;
    reg         exmem_dmem_wen;
    reg         exmem_dmem_memb;
    reg         exmem_dmem_memh;
    reg         exmem_dmem_memw;
    reg         exmem_dmem_memu;


    // EX stage: forwarding and ALU

    wire [31:0] mem_load_data;
    wire [31:0] mem_wb_value;

    wire [31:0] ex_rs1_forward;
    wire [31:0] ex_rs2_forward;

    wire exmem_can_forward;
    wire memwb_can_forward;

    //Check if EX/MEM or MEM/WB stages hold valid results for forwarding
    assign exmem_can_forward =
        exmem_valid && exmem_regwrite && !exmem_trap &&
        (exmem_rd_addr != 5'd0);

    assign memwb_can_forward =
        memwb_valid && memwb_regwrite &&
        (memwb_rd_waddr != 5'd0);

    //Forwarding MUXes: priority given to EX/MEM stage over MEM/WB stage
    assign ex_rs1_forward =
        (FWD_EN && exmem_can_forward && (exmem_rd_addr == idex_rs1_addr))
            ? mem_wb_value
        : (FWD_EN && memwb_can_forward && (memwb_rd_waddr == idex_rs1_addr))
            ? memwb_rd_wdata
        : idex_rs1_data;

    assign ex_rs2_forward =
        (FWD_EN && exmem_can_forward && (exmem_rd_addr == idex_rs2_addr))
            ? mem_wb_value
        : (FWD_EN && memwb_can_forward && (memwb_rd_waddr == idex_rs2_addr))
            ? memwb_rd_wdata
        : idex_rs2_data;

    wire [31:0] ex_alu_op1;
    wire [31:0] ex_alu_op2;
    wire [31:0] ex_alu_result;
    wire        ex_alu_eq;
    wire        ex_alu_slt;
    wire        ex_alu_sltu;

    //Select ALU inputs based on decoder control signals
    assign ex_alu_op1 = idex_op1_sel ? idex_pc : ex_rs1_forward;
    assign ex_alu_op2 = idex_op2_sel ? idex_imm : ex_rs2_forward;

    alu alu_inst (
        .i_op1      (ex_alu_op1),
        .i_op2      (ex_alu_op2),
        .i_opsel    (idex_alu_opsel),
        .i_sub      (idex_alu_sub),
        .i_unsigned (idex_alu_unsigned),
        .i_arith    (idex_alu_arith),
        .o_result   (ex_alu_result),
        .o_eq       (ex_alu_eq),
        .o_slt      (ex_alu_slt),
        .o_sltu     (ex_alu_sltu)
    );

    wire ex_branch_compare;
    wire ex_branch_taken;
    wire [31:0] ex_branch_target;
    wire [31:0] ex_jalr_target;
    wire        ex_control_taken;
    wire [31:0] ex_control_target;
    wire        ex_data_misaligned;
    wire        ex_inst_misaligned;
    wire        ex_trap;
    wire        ex_redirect;
    wire        ex_control_flush;
    wire [31:0] ex_next_pc;

    //Evaluate branch conditions using ALU comparison outputs
    assign ex_branch_compare =
        idex_branch_equal
            ? ex_alu_eq
            : idex_branch_unsigned
                ? ex_alu_sltu
                : ex_alu_slt;

    assign ex_branch_taken =
        idex_valid && idex_branch &&
        (idex_branch_invert ? !ex_branch_compare : ex_branch_compare);

    //Calculate branch and jump target addresses
    assign ex_branch_target = idex_pc + idex_imm;
    assign ex_jalr_target   = {ex_alu_result[31:1], 1'b0};

    assign ex_control_taken =
        ex_branch_taken || (idex_valid && idex_jump);

    assign ex_control_target =
        (idex_jump && idex_pc_sel) ? ex_jalr_target : ex_branch_target;

    //Detect unaligned memory accesses and PC targets
    assign ex_data_misaligned =
        (idex_dmem_ren || idex_dmem_wen) &&
        ((idex_dmem_memh && ex_alu_result[0]) ||
         (idex_dmem_memw && (|ex_alu_result[1:0])));

    assign ex_inst_misaligned =
        ex_control_taken && (ex_control_target[1:0] != 2'b00);

    assign ex_trap =
        idex_valid &&
        (!idex_legal || ex_data_misaligned || ex_inst_misaligned);

    //Redirect PC and flush IF/ID stages when control flow changes
    assign ex_redirect = ex_control_taken && !ex_trap;
    assign ex_control_flush = idex_valid && ex_control_taken;
    assign ex_next_pc = ex_redirect ? ex_control_target : idex_pc4;

    // MEM stage: data-memory interface and writeback-value selection

    wire [1:0]  mem_addr_lsbs;
    wire [3:0]  mem_access_mask;
    wire [3:0]  mem_shifted_mask;
    wire [31:0] mem_load_shifted;

    assign mem_addr_lsbs = exmem_alu_result[1:0];

    //Build byte mask for byte, half-word, and word memory operations
    assign mem_access_mask =
        exmem_dmem_memb ? 4'b0001 :
        exmem_dmem_memh ? 4'b0011 :
        exmem_dmem_memw ? 4'b1111 :
                          4'b0000;

    //Align byte mask according to the address LSBs
    assign mem_shifted_mask =
        (mem_addr_lsbs == 2'b00) ? mem_access_mask :
        (mem_addr_lsbs == 2'b01) ? {mem_access_mask[2:0], 1'b0} :
        (mem_addr_lsbs == 2'b10) ? {mem_access_mask[1:0], 2'b00} :
                                   {mem_access_mask[0], 3'b000};

    //Assign loaded word from memory
    assign mem_load_shifted =
        (mem_addr_lsbs == 2'b00) ? i_dmem_rdata :
        (mem_addr_lsbs == 2'b01) ? (i_dmem_rdata >> 8) :
        (mem_addr_lsbs == 2'b10) ? (i_dmem_rdata >> 16) :
                                   (i_dmem_rdata >> 24);

    //Sign/zero extended byte or half word load data
    assign mem_load_data =
        exmem_dmem_memb
            ? (exmem_dmem_memu
                ? {24'b0, mem_load_shifted[7:0]}
                : {{24{mem_load_shifted[7]}}, mem_load_shifted[7:0]})
        : exmem_dmem_memh
            ? (exmem_dmem_memu
                ? {16'b0, mem_load_shifted[15:0]}
                : {{16{mem_load_shifted[15]}}, mem_load_shifted[15:0]})
        : mem_load_shifted;

    //MUX to select writeback value
    assign mem_wb_value =
        exmem_rd_sel[0] ? exmem_alu_result :
        exmem_rd_sel[1] ? exmem_imm :
        exmem_rd_sel[2] ? exmem_pc4 :
        exmem_rd_sel[3] ? mem_load_data :
                          32'b0;

    // forward store data from the WB stage when needed
    wire [31:0] mem_store_data_final;
    assign mem_store_data_final =
        (FWD_EN &&
         exmem_dmem_wen &&
         memwb_can_forward &&
         (memwb_rd_waddr == exmem_rs2_addr))
            ? memwb_rd_wdata
            : exmem_rs2_data;

    assign o_dmem_addr = {exmem_alu_result[31:2], 2'b00};

    assign o_dmem_ren =
        exmem_valid && exmem_dmem_ren && !exmem_trap;

    assign o_dmem_wen =
        exmem_valid && exmem_dmem_wen && !exmem_trap;

    assign o_dmem_mask =
        (o_dmem_ren || o_dmem_wen) ? mem_shifted_mask : 4'b0000;

    //Align store data to the target byte lane in data memory
    assign o_dmem_wdata =
        (mem_addr_lsbs == 2'b00) ? mem_store_data_final :
        (mem_addr_lsbs == 2'b01) ? (mem_store_data_final << 8) :
        (mem_addr_lsbs == 2'b10) ? (mem_store_data_final << 16) :
                                   (mem_store_data_final << 24);

    // MEM/WB pipeline registers

    reg  [31:0] memwb_inst;
    reg  [31:0] memwb_pc;
    reg  [31:0] memwb_next_pc;
    reg         memwb_trap;
    reg         memwb_halt;

    reg  [4:0]  memwb_rs1_addr;
    reg  [4:0]  memwb_rs2_addr;
    reg  [31:0] memwb_rs1_data;
    reg  [31:0] memwb_rs2_data;

    reg  [31:0] memwb_dmem_addr;
    reg         memwb_dmem_ren;
    reg         memwb_dmem_wen;
    reg  [3:0]  memwb_dmem_mask;
    reg  [31:0] memwb_dmem_wdata;
    reg  [31:0] memwb_dmem_rdata;

    // hazard detection

    wire hazard_idex_rs1;
    wire hazard_idex_rs2;
    wire hazard_exmem_rs1;
    wire hazard_exmem_rs2;
    wire hazard_memwb_rs1;
    wire hazard_memwb_rs2;
    wire hazard_idex;
    wire hazard_exmem;
    wire hazard_memwb;
    wire pipeline_stall;

    //detect hazards when ID instruction reads a register being written by later stages
    assign hazard_idex_rs1 =
        ifid_valid && idex_valid && idex_legal &&
        (idex_rd_addr != 5'd0) && (id_rs1_addr != 5'd0) &&
        (id_rs1_addr == idex_rd_addr);

    assign hazard_idex_rs2 =
        ifid_valid && idex_valid && idex_legal &&
        (idex_rd_addr != 5'd0) && (id_rs2_addr != 5'd0) &&
        (id_rs2_addr == idex_rd_addr);

    assign hazard_idex = hazard_idex_rs1 || hazard_idex_rs2;

    assign hazard_exmem_rs1 =
        ifid_valid && exmem_valid && exmem_regwrite && !exmem_trap &&
        (exmem_rd_addr != 5'd0) && (id_rs1_addr != 5'd0) &&
        (id_rs1_addr == exmem_rd_addr);

    assign hazard_exmem_rs2 =
        ifid_valid && exmem_valid && exmem_regwrite && !exmem_trap &&
        (exmem_rd_addr != 5'd0) && (id_rs2_addr != 5'd0) &&
        (id_rs2_addr == exmem_rd_addr);

    assign hazard_exmem = hazard_exmem_rs1 || hazard_exmem_rs2;

    assign hazard_memwb_rs1 =
        ifid_valid && memwb_valid && memwb_regwrite &&
        (memwb_rd_waddr != 5'd0) && (id_rs1_addr != 5'd0) &&
        (id_rs1_addr == memwb_rd_waddr);

    assign hazard_memwb_rs2 =
        ifid_valid && memwb_valid && memwb_regwrite &&
        (memwb_rd_waddr != 5'd0) && (id_rs2_addr != 5'd0) &&
        (id_rs2_addr == memwb_rd_waddr);

    assign hazard_memwb = hazard_memwb_rs1 || hazard_memwb_rs2;

    //Force a pipeline stall when forwarding is disabled and hazards are detected
    assign pipeline_stall =
        !FWD_EN &&
        (hazard_idex || hazard_exmem || ((!BYPASS_EN) && hazard_memwb));

    // pipeline state updates

    always @(posedge i_clk) begin
        if (i_rst) begin
            pc          <= RESET_ADDR;
            stop_fetch  <= 1'b0;

            ifid_valid  <= 1'b0;
            idex_valid  <= 1'b0;
            exmem_valid <= 1'b0;
            memwb_valid <= 1'b0;
        end
        else begin
            // older EX instruction always advances into MEM
            exmem_valid <= idex_valid;
            exmem_inst  <= idex_inst;
            exmem_pc    <= idex_pc;
            exmem_next_pc <= ex_next_pc;

            exmem_rs1_addr <= idex_rs1_addr;
            exmem_rs2_addr <= idex_rs2_addr;
            exmem_rs1_data <= ex_rs1_forward;
            exmem_rs2_data <= ex_rs2_forward;

            exmem_rd_addr     <= idex_rd_addr;
            exmem_alu_result  <= ex_alu_result;
            exmem_imm          <= idex_imm;
            exmem_pc4          <= idex_pc4;
            exmem_trap         <= ex_trap;
            exmem_halt         <= idex_halt;
            exmem_regwrite     <= idex_valid && idex_legal &&
                                  !idex_halt && !ex_trap &&
                                  (idex_rd_addr != 5'd0);
            exmem_rd_sel       <= idex_rd_sel;

            exmem_dmem_ren  <= idex_valid && idex_dmem_ren && !ex_trap;
            exmem_dmem_wen  <= idex_valid && idex_dmem_wen && !ex_trap;
            exmem_dmem_memb <= idex_dmem_memb;
            exmem_dmem_memh <= idex_dmem_memh;
            exmem_dmem_memw <= idex_dmem_memw;
            exmem_dmem_memu <= idex_dmem_memu;

            // MEM advances into WB
            // loads capture the word read in MEM
            memwb_valid <= exmem_valid;
            memwb_inst  <= exmem_inst;
            memwb_pc    <= exmem_pc;
            memwb_next_pc <= exmem_next_pc;
            memwb_trap  <= exmem_trap;
            memwb_halt  <= exmem_halt;

            memwb_rs1_addr <= exmem_rs1_addr;
            memwb_rs2_addr <= exmem_rs2_addr;
            memwb_rs1_data <= exmem_rs1_data;
            memwb_rs2_data <=
                exmem_dmem_wen ? mem_store_data_final : exmem_rs2_data;

            memwb_rd_waddr <=
                (exmem_valid && exmem_regwrite && !exmem_trap)
                    ? exmem_rd_addr : 5'd0;
            memwb_rd_wdata <= mem_wb_value;
            memwb_regwrite <= exmem_valid && exmem_regwrite &&
                              !exmem_trap;

            memwb_dmem_addr <= o_dmem_addr;
            memwb_dmem_ren  <= o_dmem_ren;
            memwb_dmem_wen  <= o_dmem_wen;
            memwb_dmem_mask <= o_dmem_mask;
            memwb_dmem_wdata <= o_dmem_wdata;
            memwb_dmem_rdata <= o_dmem_ren ? i_dmem_rdata : 32'b0;

            // taken control flow always flushes younger instructions
            // misaligned target traps and continues at the old PC + 4
            if (ex_control_flush) begin
                pc <= ex_redirect ? ex_control_target : idex_pc4;
                ifid_valid <= 1'b0;
                ifid_inst  <= NOP;
                idex_valid <= 1'b0;
                idex_inst  <= NOP;
            end
            else if (pipeline_stall) begin
                // hold PC and IF/ID; insert a NOP bubble into EX
                pc         <= pc;
                ifid_valid <= ifid_valid;
                ifid_inst  <= ifid_inst;
                ifid_pc    <= ifid_pc;
                idex_valid <= 1'b0;
                idex_inst  <= NOP;
            end
            else if (id_halt) begin
                // keep the ebreak in the pipeline, but discard younger work
                stop_fetch <= 1'b1;
                pc         <= pc;
                ifid_valid <= 1'b0;
                ifid_inst  <= NOP;

                idex_valid <= 1'b1;
                idex_inst  <= ifid_inst;
                idex_pc    <= ifid_pc;
                idex_pc4   <= ifid_pc + 32'd4;
                idex_rs1_addr <= 5'd0;
                idex_rs2_addr <= 5'd0;
                idex_rd_addr  <= 5'd0;
                idex_rs1_data <= 32'b0;
                idex_rs2_data <= 32'b0;
                idex_imm      <= dec_imm;
                idex_legal    <= dec_legal;
                idex_halt     <= 1'b1;
                idex_op1_sel  <= dec_op1_sel;
                idex_op2_sel  <= dec_op2_sel;
                idex_alu_opsel <= dec_alu_opsel;
                idex_alu_sub   <= dec_alu_sub;
                idex_alu_unsigned <= dec_alu_unsigned;
                idex_alu_arith <= dec_alu_arith;
                idex_branch   <= 1'b0;
                idex_jump     <= 1'b0;
                idex_branch_equal <= dec_branch_equal;
                idex_branch_unsigned <= dec_branch_unsigned;
                idex_branch_invert <= dec_branch_invert;
                idex_pc_sel   <= dec_pc_sel;
                idex_dmem_ren <= 1'b0;
                idex_dmem_wen <= 1'b0;
                idex_dmem_memb <= dec_dmem_memb;
                idex_dmem_memh <= dec_dmem_memh;
                idex_dmem_memw <= dec_dmem_memw;
                idex_dmem_memu <= dec_dmem_memu;
                idex_rd_sel   <= 4'b0000;
            end
            else if (stop_fetch) begin
                pc         <= pc;
                ifid_valid <= 1'b0;
                ifid_inst  <= NOP;
                idex_valid <= 1'b0;
                idex_inst  <= NOP;
            end
            else begin
                // normal IF and ID advancement
                pc         <= pc_plus4;
                ifid_valid <= 1'b1;
                ifid_inst  <= i_imem_rdata;
                ifid_pc    <= pc;

                idex_valid <= ifid_valid;
                idex_inst  <= ifid_inst;
                idex_pc    <= ifid_pc;
                idex_pc4   <= ifid_pc + 32'd4;

                idex_rs1_addr <= id_rs1_addr;
                idex_rs2_addr <= id_rs2_addr;
                idex_rd_addr  <= dec_legal ? dec_rd : 5'd0;
                idex_rs1_data <= (id_rs1_addr != 5'd0)
                                    ? rf_rs1_data : 32'b0;
                idex_rs2_data <= (id_rs2_addr != 5'd0)
                                    ? rf_rs2_data : 32'b0;
                idex_imm      <= dec_imm;

                idex_legal    <= dec_legal;
                idex_halt     <= id_halt;
                idex_op1_sel  <= dec_op1_sel;
                idex_op2_sel  <= dec_op2_sel;
                idex_alu_opsel <= dec_alu_opsel;
                idex_alu_sub   <= dec_alu_sub;
                idex_alu_unsigned <= dec_alu_unsigned;
                idex_alu_arith <= dec_alu_arith;

                idex_branch   <= dec_legal && dec_branch;
                idex_jump     <= dec_legal && dec_jump;
                idex_branch_equal <= dec_branch_equal;
                idex_branch_unsigned <= dec_branch_unsigned;
                idex_branch_invert <= dec_branch_invert;
                idex_pc_sel   <= dec_pc_sel;

                idex_dmem_ren <= dec_legal && dec_dmem_ren;
                idex_dmem_wen <= dec_legal && dec_dmem_wen;
                idex_dmem_memb <= dec_dmem_memb;
                idex_dmem_memh <= dec_dmem_memh;
                idex_dmem_memw <= dec_dmem_memw;
                idex_dmem_memu <= dec_dmem_memu;
                idex_rd_sel   <= dec_legal ? dec_rd_sel : 4'b0000;
            end
        end
    end

    // retire interface

    //Assign writeback stage signals directly to the retirement tracking interface
    assign o_retire_valid = memwb_valid;
    assign o_retire_inst  = memwb_inst;
    assign o_retire_trap  = memwb_valid && memwb_trap;
    assign o_retire_halt  = memwb_valid && memwb_halt;

    assign o_retire_rs1_raddr = memwb_rs1_addr;
    assign o_retire_rs1_rdata = memwb_rs1_data;
    assign o_retire_rs2_raddr = memwb_rs2_addr;
    assign o_retire_rs2_rdata = memwb_rs2_data;

    assign o_retire_rd_waddr =
        (memwb_valid && memwb_regwrite) ? memwb_rd_waddr : 5'd0;
    assign o_retire_rd_wdata = memwb_rd_wdata;

    assign o_retire_pc      = memwb_pc;
    assign o_retire_next_pc = memwb_next_pc;

    assign o_retire_dmem_addr  = memwb_dmem_addr;
    assign o_retire_dmem_ren   = memwb_dmem_ren;
    assign o_retire_dmem_wen   = memwb_dmem_wen;
    assign o_retire_dmem_mask  = memwb_dmem_mask;
    assign o_retire_dmem_wdata = memwb_dmem_wdata;
    assign o_retire_dmem_rdata = memwb_dmem_rdata;

endmodule

`default_nettype wire