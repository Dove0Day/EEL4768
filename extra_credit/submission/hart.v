`default_nettype none

// Keep your phase 6 PC, IF/ID, decoder, imm, register file and FPU here. EX
// through WB are replaced by the Tomasulo-style backend (ROB, RS, RAT, CDB,
// LSU) described in `documentation/phase_7.pdf`.
module hart #(
    // After reset, the program counter (PC) should be initialized to this
    // address and start executing instructions from there.
    parameter RESET_ADDR = 32'h00400000,
    // When set, register file bypassing is enabled.
    parameter BYPASS_EN = 1,
    // Data cache configuration. Pass EVICT_POLICY, NUM_WAYS, CACHE_SIZE,
    // BLOCK_SIZE and PREFETCH_EN down to your phase 5 data cache.
    // WRITE_ALLOCATE = 0 is the phase 5 write policy (write-back on a hit,
    // write-through with no allocate on a miss), which your cache already
    // implements, so it needs no such parameter.
    parameter EVICT_POLICY   = 0,
    parameter NUM_WAYS       = 1,
    parameter CACHE_SIZE     = 16,
    parameter BLOCK_SIZE     = 128,
    parameter PREFETCH_EN    = 0,
    parameter WRITE_ALLOCATE = 0
) (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Instruction fetch goes through a read only instruction memory (imem)
    // port. The port accepts a 32-bit address (e.g. from the program counter)
    // per cycle and combinationally returns a 32-bit instruction word, as in
    // phase 4. Only the data side goes through a cache in this phase.
    //
    // 32-bit read address for the instruction memory. This is expected to be
    // 4 byte aligned - that is, the two LSBs should be zero.
    output wire [31:0] o_imem_raddr,
    // Instruction word fetched from memory, available on the same cycle.
    input  wire [31:0] i_imem_rdata,
    // Main memory port behind your data cache, one block (BLOCK_SIZE bytes)
    // per transfer, against a main memory with a fixed delay:
    //  * o_mem_rd is a one-cycle request for the line at o_mem_rd_addr
    //    (line aligned); i_mem_valid is high for one cycle when that line
    //    is on i_mem_rd_data. Requests are answered in order.
    //  * o_mem_wr is a one-cycle line write; o_mem_wr_be has one bit per
    //    byte (all ones for a dirty write-back, only the stored bytes for a
    //    write-through).
    //  * i_mem_ready is high when main memory can take a request. Your
    //    phase 5 cache has no such input; it can stay unused.
    input  wire                        i_mem_ready,
    input  wire                        i_mem_valid,
    input  wire [BLOCK_SIZE*8-1:0]     i_mem_rd_data,
    output wire                        o_mem_rd,
    output wire                        o_mem_wr,
    output wire [31:0]                 o_mem_rd_addr,
    output wire [31:0]                 o_mem_wr_addr,
    output wire [BLOCK_SIZE*8-1:0]     o_mem_wr_data,
    output wire [BLOCK_SIZE-1:0]       o_mem_wr_be,
    // The output `retire` interface is used to signal to the testbench that
    // the CPU has completed and retired an instruction. A single cycle
    // implementation will assert this every cycle; however, a pipelined
    // implementation that needs to stall (due to internal hazards or waiting
    // on memory accesses) will not assert the signal on cycles where no
    // instruction commits from the ROB head.
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
    // The first source operand the instruction being retired actually used
    // (the value captured at issue, or when its producer completed on the
    // CDB). If rs1 is 5'd0, this should also be 32'd0.
    output wire [31:0] o_retire_rs1_rdata,
    // The second source operand the instruction being retired actually used
    // (the value captured at issue, or when its producer completed on the
    // CDB). If rs2 is 5'd0, this should also be 32'd0.
    output wire [31:0] o_retire_rs2_rdata,
    // The destination register address written by the instruction being
    // retired. If the instruction does not write to a register (like `sw`),
    // this should be 5'd0.
    output wire [ 4:0] o_retire_rd_waddr,
    // The destination register data written to the register file when this
    // instruction commits. If rd is 5'd0, this field is
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
    output wire [31:0] o_retire_next_pc,
    // The `complete` interface reports each result broadcast on the common
    // data bus (CDB). See "Complete interface" in `documentation/phase_7.pdf`.
    //
    // Asserted on a cycle with a CDB broadcast. At most one per cycle. If
    // this is not asserted, the other complete signals are don't cares.
    // Pulse only on a CDB grant; stores, ebreak/illegal and misaligned traps
    // never pulse it.
    output wire        o_complete_valid,
    // ROB tag of the completing instruction.
    output wire [ 2:0] o_complete_tag,
    // Architectural rd of the completing instruction (5'd0 if it writes no
    // register).
    output wire [ 4:0] o_complete_rd,
    // Value on the CDB (ALU result, load data, or link address).
    output wire [31:0] o_complete_value,
    // PC of the completing instruction.
    output wire [31:0] o_complete_pc,
    // F extension retire fields. The floating-point source registers read
    // by the instruction being retired (addresses are the instruction's rs1,
    // rs2 and rs3 fields) and their values; they are only meaningful for
    // instructions that read them.
    output wire [ 4:0] o_retire_frs1_raddr,
    output wire [31:0] o_retire_frs1_rdata,
    output wire [ 4:0] o_retire_frs2_raddr,
    output wire [31:0] o_retire_frs2_rdata,
    output wire [ 4:0] o_retire_frs3_raddr,
    output wire [31:0] o_retire_frs3_rdata,
    // Asserted when the instruction being retired writes floating-point
    // register `o_retire_frd_waddr` with `o_retire_frd_wdata`. (f0 is an
    // ordinary register, so an enable is needed.)
    output wire        o_retire_frd_wen,
    output wire [ 4:0] o_retire_frd_waddr,
    output wire [31:0] o_retire_frd_wdata,
    // The accrued floating-point exception flags (fflags) after the
    // instruction being retired.
    output wire [ 4:0] o_retire_fflags

`ifdef RISCV_FORMAL
    ,`RVFI_OUTPUTS,
`endif
);

// Write your code here.

    //Default NOP instruction word
    localparam [31:0] NOP = 32'h00000013;

    // IF stage

    // PC Register and fetching
    reg  [31:0] pc; // program counter
    reg         stop_fetch; //flag to freeze PC fetch
    wire [31:0] pc_plus4; // address of next instruction

    assign pc_plus4     = pc + 32'd4;

    // [PHASE 7 NEW] Drive combinational instruction memory directly from PC
    assign o_imem_raddr = pc;

    // [PHASE 7 REMOVED] icache_ren, icache_ready, icache_rdata, if_stall,
    //                   mem_stall, cache_stall, ex_stall, pipe_stall, and
    //                   the `icache` instance (no instruction cache in Phase 7).

    // [PHASE 7 NEW] Control signals coming back from the Tomasulo OoO backend
    wire        ooo_taken;       // High when a branch/jump resolves as taken
    wire [31:0] ooo_pc_jump;     // Redirect target PC from resolved branch/jump
    wire        ooo_id_hold;     // High when ROB/RS/LSU is full or branch in-flight
    wire        ooo_fetch_stall; // Optional: injects NOP into IF/ID if backend requests

    // IF/ID pipeline registers
    reg         ifid_valid;
    reg  [31:0] ifid_inst;
    reg  [31:0] ifid_pc;

    // dynamic branch prediction
    // 2-bit BHT + BTB (predicted in IF)
    localparam BP_IDX_W   = 6;
    localparam BP_ENTRIES = 64;
    localparam BP_TAG_W   = 32 - 2 - BP_IDX_W;

    reg [1:0]          bht_q       [0:BP_ENTRIES-1];  // 00 SNT 01 WNT 10 WT 11 ST
    reg                btb_valid_q [0:BP_ENTRIES-1];
    reg [BP_TAG_W-1:0] btb_tag_q   [0:BP_ENTRIES-1];
    reg [31:0]         btb_tgt_q   [0:BP_ENTRIES-1];

    // update bus from the backend (driven when a conditional branch resolves)
    wire        bp_upd_valid;
    wire [31:0] bp_upd_pc;
    wire        bp_upd_taken;
    wire [31:0] bp_upd_target;

    // prediction for the instruction at pc (imem is combinational)
    wire [BP_IDX_W-1:0] bp_rd_idx;
    wire [BP_TAG_W-1:0] bp_rd_tag;
    wire                if_is_branch;
    wire                if_pred_taken;
    wire [31:0]         if_pred_target;
    wire [31:0]         if_next_pc;

    assign bp_rd_idx      = pc[BP_IDX_W+1:2];
    assign bp_rd_tag      = pc[31:BP_IDX_W+2];
    assign if_is_branch   = (i_imem_rdata[6:0] == 7'b1100011);
    assign if_pred_taken  = if_is_branch &&
                            btb_valid_q[bp_rd_idx] &&
                            (btb_tag_q[bp_rd_idx] == bp_rd_tag) &&
                            bht_q[bp_rd_idx][1];
    assign if_pred_target = btb_tgt_q[bp_rd_idx];
    assign if_next_pc     = if_pred_taken ? if_pred_target : pc_plus4;

    // prediction travels with the instruction
    reg         ifid_pred_taken;
    reg  [31:0] ifid_pred_target;

    // BHT / BTB update
    wire [BP_IDX_W-1:0] bp_upd_idx;
    assign bp_upd_idx = bp_upd_pc[BP_IDX_W+1:2];

    genvar bp_i;
    generate
        for (bp_i = 0; bp_i < BP_ENTRIES;
             bp_i = bp_i + 1) begin : gen_bp

        localparam [BP_IDX_W-1:0] ENTRY_IDX = bp_i;

        wire update_here;

        assign update_here = bp_upd_valid &&
                            (bp_upd_idx == ENTRY_IDX);

            always @(posedge i_clk) begin
                if (i_rst) begin
                    bht_q[bp_i]       <= 2'b01;
                    btb_valid_q[bp_i] <= 1'b0;
                end
                else if (update_here) begin
                    if (bp_upd_taken) begin
                        if (bht_q[bp_i] != 2'b11)
                            bht_q[bp_i] <= bht_q[bp_i] + 2'd1;

                        btb_valid_q[bp_i] <= 1'b1;
                        btb_tag_q[bp_i]   <= bp_upd_pc[31:BP_IDX_W+2];
                        btb_tgt_q[bp_i]   <= bp_upd_target;
                    end
                    else if (bht_q[bp_i] != 2'b00) begin
                        bht_q[bp_i] <= bht_q[bp_i] - 2'd1;
                    end
                end
            end
        end
    endgenerate

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

    wire [4:0]  dec_rd_sel; // writeback data source ([4] = FPU integer result)
    // phase 6 decoder outputs
    wire        dec_mext;    // RV32M instruction (ALU multiply/divide)
    wire        dec_fpu;     // executed by the FPU (OP-FP, fused, CSR)
    wire        dec_frs1_en; // reads FP rs1
    wire        dec_frs2_en; // reads FP rs2 (includes fsw data)
    wire        dec_frs3_en; // reads FP rs3 (fused only)
    wire [4:0]  dec_rs3;
    wire        dec_frd_en;  // writes FP rd
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
        .o_pc_sel          (dec_pc_sel),

        .o_mext            (dec_mext),
        .o_fpu             (dec_fpu),
        .o_frs1_en         (dec_frs1_en),
        .o_frs2_en         (dec_frs2_en),
        .o_frs3_en         (dec_frs3_en),
        .o_rs3             (dec_rs3),
        .o_frd_en          (dec_frd_en)
    );

    // illegal instructions report no source-register reads
    wire [4:0] id_rs1_addr;
    wire [4:0] id_rs2_addr;
    wire       id_halt;

    // phase 6: an operand that comes from the FP file is not an integer read
    // (and the CSR immediate forms use the rs1 field as an immediate)
    wire id_csr_imm;
    assign id_csr_imm  = (ifid_inst[6:0] == 7'b1110011) && ifid_inst[14];
    assign id_rs1_addr = (ifid_valid && dec_legal && !dec_frs1_en && !id_csr_imm)
                         ? dec_rs1 : 5'd0;
    assign id_rs2_addr = (ifid_valid && dec_legal && !dec_frs2_en)
                         ? dec_rs2 : 5'd0;

    // phase 6: FP registers read/written by the ID instruction. f0 is a
    // normal register, so each one has an enable instead of using 0 as "none"
    wire       id_frs1_en, id_frs2_en, id_frs3_en, id_frd_en;
    wire [4:0] id_frs1_addr, id_frs2_addr, id_frs3_addr;

    assign id_frs1_en   = ifid_valid && dec_legal && dec_frs1_en;
    assign id_frs2_en   = ifid_valid && dec_legal && dec_frs2_en;
    assign id_frs3_en   = ifid_valid && dec_legal && dec_frs3_en;
    assign id_frd_en    = ifid_valid && dec_legal && dec_frd_en;
    assign id_frs1_addr = id_frs1_en ? ifid_inst[19:15] : 5'd0;
    assign id_frs2_addr = id_frs2_en ? ifid_inst[24:20] : 5'd0;
    assign id_frs3_addr = id_frs3_en ? dec_rs3          : 5'd0;
    assign id_halt     = ifid_valid && dec_halt;

    // Architectural Register File (Kept from Phase 6)
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;
    wire [31:0] rf_frs1_data;
    wire [31:0] rf_frs2_data;
    wire [31:0] rf_frs3_data;

    // [PHASE 7 NEW] RF writeback now comes from ROB commit (replaces memwb_* regs)
    wire        rob_commit_rf_wen;
    wire [4:0]  rob_commit_rd_waddr;
    wire [31:0] rob_commit_rd_wdata;
    wire        rob_commit_frd_wen;
    wire [4:0]  rob_commit_frd_waddr;
    wire [31:0] rob_commit_frd_wdata;

    wire [4:0] rf_waddr;
    assign rf_waddr = rob_commit_rf_wen ? rob_commit_rd_waddr : 5'd0;

    rf #(
        .BYPASS_EN(BYPASS_EN)
    ) rf_inst (
        .i_clk        (i_clk),
        .i_rst        (i_rst),

        .i_rs1_raddr  (id_rs1_addr),
        .o_rs1_rdata  (rf_rs1_data),
        .i_rs2_raddr  (id_rs2_addr),
        .o_rs2_rdata  (rf_rs2_data),

        .i_rd_waddr   (rf_waddr),
        .i_rd_wdata   (rob_commit_rd_wdata),

        .i_frs1_raddr (id_frs1_addr),
        .o_frs1_rdata (rf_frs1_data),
        .i_frs2_raddr (id_frs2_addr),
        .o_frs2_rdata (rf_frs2_data),
        .i_frs3_raddr (id_frs3_addr),
        .o_frs3_rdata (rf_frs3_data),
        .i_frd_wen    (rob_commit_frd_wen),
        .i_frd_waddr  (rob_commit_frd_waddr),
        .i_frd_wdata  (rob_commit_frd_wdata)
    );

    //Kept from phase 5/6, but data cache is now driven by OoO LSU
    // [PHASE 7 NEW] Wires connecting the OoO backend's LSU to the Phase 5 dcache
    wire        dcache_ren;
    wire        dcache_wen;
    wire [31:0] dcache_addr;
    wire [3:0]  dcache_mask;
    wire [31:0] dcache_wdata;
    wire        dcache_ready;
    wire [31:0] dcache_rdata;

    cache #(
        .EVICT_POLICY (EVICT_POLICY),
        .NUM_WAYS     (NUM_WAYS),
        .CACHE_SIZE   (CACHE_SIZE),
        .BLOCK_SIZE   (BLOCK_SIZE),
        .PREFETCH_EN  (PREFETCH_EN)
    ) dcache (
        .i_clk         (i_clk),
        .i_rst         (i_rst),
        .i_ren         (dcache_ren),
        .i_wen         (dcache_wen),
        .i_addr        (dcache_addr),
        .i_mask        (dcache_mask),
        .i_wdata       (dcache_wdata),
        .o_ready       (dcache_ready),
        .o_rdata       (dcache_rdata),
        // [PHASE 7 NEW] Connected to the new o_mem_* / i_mem_* hart ports
        .o_mem_rd      (o_mem_rd),
        .o_mem_rd_addr (o_mem_rd_addr),
        .i_mem_valid   (i_mem_valid),
        .i_mem_rd_data (i_mem_rd_data),
        .o_mem_wr      (o_mem_wr),
        .o_mem_wr_addr (o_mem_wr_addr),
        .o_mem_wr_data (o_mem_wr_data),
        .o_mem_wr_be   (o_mem_wr_be)
    );
    // =========================================================================
    // TOMASULO OUT-OF-ORDER BACKEND (Replaces Phase 6 EX -> WB)
    // =========================================================================
    // [PHASE 7 REMOVED]
    //  - ID/EX, EX/MEM, MEM/WB pipeline registers
    //  - EX/MEM and MEM/WB forwarding muxes
    //  - Phase 6 hazard detection (hazard_idex, fp_hazard_*, load_use_hazard, etc.)
    //  - Standalone `alu` and `fpu` instances (now live inside `ooo_core` with
    //    dual FPUs, RAT, ROB, RS, CDB/cdb_arb, and LSU)

    // [PHASE 7 NEW] Instantiate the Tomasulo OoO Backend
    ooo_core ooo_core_inst (
        .i_clk                (i_clk),
        .i_rst                (i_rst),

        // From IF/ID Frontend & Decoder
        .i_id_valid           (ifid_valid),
        .i_id_inst            (ifid_inst),
        .i_id_pc              (ifid_pc),

        // used for dynamic branch prediction
        .i_id_pred_taken      (ifid_pred_taken),
        .i_id_pred_target     (ifid_pred_target),
        
        .i_dec_legal          (dec_legal),
        .i_dec_halt           (id_halt),
        .i_dec_rs1            (id_rs1_addr),
        .i_dec_rs2            (id_rs2_addr),
        .i_dec_rd             (id_frd_en ? ifid_inst[11:7] :
                       (dec_legal ? dec_rd : 5'd0)),
        .i_dec_imm            (dec_imm),
        .i_dec_op1_sel        (dec_op1_sel),
        .i_dec_op2_sel        (dec_op2_sel),
        .i_dec_alu_opsel      (dec_alu_opsel),
        .i_dec_alu_sub        (dec_alu_sub),
        .i_dec_alu_unsigned   (dec_alu_unsigned),
        .i_dec_alu_arith      (dec_alu_arith),
        .i_dec_branch         (dec_legal && dec_branch),
        .i_dec_jump           (dec_legal && dec_jump),
        .i_dec_branch_equal   (dec_branch_equal),
        .i_dec_branch_unsigned(dec_branch_unsigned),
        .i_dec_branch_invert  (dec_branch_invert),
        .i_dec_pc_sel         (dec_pc_sel),
        .i_dec_dmem_ren       (dec_legal && dec_dmem_ren),
        .i_dec_dmem_wen       (dec_legal && dec_dmem_wen),
        .i_dec_dmem_memb      (dec_dmem_memb),
        .i_dec_dmem_memh      (dec_dmem_memh),
        .i_dec_dmem_memw      (dec_dmem_memw),
        .i_dec_dmem_memu      (dec_dmem_memu),
        .i_dec_rd_sel         (dec_legal ? dec_rd_sel : 5'b00000),
        .i_dec_mext           (dec_legal && dec_mext),
        .i_dec_fpu            (dec_legal && dec_fpu),
        .i_dec_frs1_en        (id_frs1_en),
        .i_dec_frs2_en        (id_frs2_en),
        .i_dec_frs3_en        (id_frs3_en),
        .i_dec_frd_en         (id_frd_en),
        .i_dec_frs1_addr      (id_frs1_addr),
        .i_dec_frs2_addr      (id_frs2_addr),
        .i_dec_frs3_addr      (id_frs3_addr),

        // Architectural RF Read Data (at Issue)
        .i_rf_rs1_data        ((id_rs1_addr != 5'd0) ? rf_rs1_data : 32'b0),
        .i_rf_rs2_data        ((id_rs2_addr != 5'd0) ? rf_rs2_data : 32'b0),
        .i_rf_frs1_data       (rf_frs1_data),
        .i_rf_frs2_data       (rf_frs2_data),
        .i_rf_frs3_data       (rf_frs3_data),

        // Architectural RF Writeback (at ROB Commit)
        .o_rf_wen             (rob_commit_rf_wen),
        .o_rf_waddr           (rob_commit_rd_waddr),
        .o_rf_wdata           (rob_commit_rd_wdata),
        .o_frd_wen            (rob_commit_frd_wen),
        .o_frd_waddr          (rob_commit_frd_waddr),
        .o_frd_wdata          (rob_commit_frd_wdata),

        // Frontend Flow Control (PC redirect & stalls)
        .o_taken              (ooo_taken),
        .o_pc_jump            (ooo_pc_jump),
        .o_id_hold            (ooo_id_hold),
        .o_fetch_stall        (ooo_fetch_stall),

        // for dynamic branch prediction
        .o_bp_upd_valid       (bp_upd_valid),
        .o_bp_upd_pc          (bp_upd_pc),
        .o_bp_upd_taken       (bp_upd_taken),
        .o_bp_upd_target      (bp_upd_target),

        // LSU <-> Data Cache Interface
        .o_dcache_ren         (dcache_ren),
        .o_dcache_wen         (dcache_wen),
        .o_dcache_addr        (dcache_addr),
        .o_dcache_mask        (dcache_mask),
        .o_dcache_wdata       (dcache_wdata),
        .i_dcache_ready       (dcache_ready),
        .i_dcache_rdata       (dcache_rdata),

        // Retire Interface (ROB head, in program order)
        .o_retire_valid       (o_retire_valid),
        .o_retire_inst        (o_retire_inst),
        .o_retire_trap        (o_retire_trap),
        .o_retire_halt        (o_retire_halt),
        .o_retire_rs1_raddr   (o_retire_rs1_raddr),
        .o_retire_rs2_raddr   (o_retire_rs2_raddr),
        .o_retire_rs1_rdata   (o_retire_rs1_rdata),
        .o_retire_rs2_rdata   (o_retire_rs2_rdata),
        .o_retire_rd_waddr    (o_retire_rd_waddr),
        .o_retire_rd_wdata    (o_retire_rd_wdata),
        .o_retire_dmem_addr   (o_retire_dmem_addr),
        .o_retire_dmem_mask   (o_retire_dmem_mask),
        .o_retire_dmem_ren    (o_retire_dmem_ren),
        .o_retire_dmem_wen    (o_retire_dmem_wen),
        .o_retire_dmem_rdata  (o_retire_dmem_rdata),
        .o_retire_dmem_wdata  (o_retire_dmem_wdata),
        .o_retire_pc          (o_retire_pc),
        .o_retire_next_pc     (o_retire_next_pc),
        .o_retire_frs1_raddr  (o_retire_frs1_raddr),
        .o_retire_frs1_rdata  (o_retire_frs1_rdata),
        .o_retire_frs2_raddr  (o_retire_frs2_raddr),
        .o_retire_frs2_rdata  (o_retire_frs2_rdata),
        .o_retire_frs3_raddr  (o_retire_frs3_raddr),
        .o_retire_frs3_rdata  (o_retire_frs3_rdata),
        .o_retire_frd_wen     (o_retire_frd_wen),
        .o_retire_frd_waddr   (o_retire_frd_waddr),
        .o_retire_frd_wdata   (o_retire_frd_wdata),
        .o_retire_fflags      (o_retire_fflags),

        // Complete Interface (CDB broadcast)
        .o_complete_valid     (o_complete_valid),
        .o_complete_tag       (o_complete_tag),
        .o_complete_rd        (o_complete_rd),
        .o_complete_value     (o_complete_value),
        .o_complete_pc        (o_complete_pc)
    );
    // =========================================================================
    // 5. FRONTEND STATE UPDATES (PC & IF/ID)
    // =========================================================================
    // [PHASE 7 NEW] Replaced Phase 6's giant 5-stage always block with a clean
    // frontend-only always block controlled by ooo_taken, ooo_id_hold, and
    // ooo_fetch_stall.
        always @(posedge i_clk) begin
        if (i_rst) begin
            pc               <= RESET_ADDR;
            stop_fetch       <= 1'b0;
            ifid_valid       <= 1'b0;
            ifid_inst        <= NOP;
            ifid_pc          <= RESET_ADDR;
            ifid_pred_taken  <= 1'b0;
            ifid_pred_target <= 32'd0;
        end
        else if (ooo_taken) begin
            // mispredict (or jump) resolved: redirect to the CORRECT next pc, squash IF/ID
            pc               <= ooo_pc_jump;
            stop_fetch       <= 1'b0;
            ifid_valid       <= 1'b0;
            ifid_inst        <= NOP;
            ifid_pred_taken  <= 1'b0;
        end
        else if (ooo_id_hold) begin
            pc               <= pc;
            ifid_valid       <= ifid_valid;
            ifid_inst        <= ifid_inst;
            ifid_pc          <= ifid_pc;
            ifid_pred_taken  <= ifid_pred_taken;
            ifid_pred_target <= ifid_pred_target;
        end
        else if (id_halt) begin
            stop_fetch       <= 1'b1;
            pc               <= pc;
            ifid_valid       <= 1'b0;
            ifid_inst        <= NOP;
            ifid_pred_taken  <= 1'b0;
        end
        else if (stop_fetch || ooo_fetch_stall) begin
            pc               <= pc;
            ifid_valid       <= 1'b0;
            ifid_inst        <= NOP;
            ifid_pred_taken  <= 1'b0;
        end
        else begin
            pc               <= if_next_pc;          // <-- was pc_plus4
            ifid_valid       <= 1'b1;
            ifid_inst        <= i_imem_rdata;
            ifid_pc          <= pc;
            ifid_pred_taken  <= if_pred_taken;
            ifid_pred_target <= if_pred_target;
        end
    end

endmodule
`default_nettype wire
