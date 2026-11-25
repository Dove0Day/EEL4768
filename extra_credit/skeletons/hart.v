`default_nettype none

// Keep your phase 6 PC, IF/ID, decoder, imm, register file and FPU here. EX
// through WB are replaced by the Tomasulo-style backend (ROB, RS, RAT, CDB,
// LSU) described in `documentation/phase_7.pdf`.
module hart #(
    // After reset, the program counter (PC) should be initialized to this
    // address and start executing instructions from there.
    parameter RESET_ADDR = 32'h00000000,
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

endmodule
