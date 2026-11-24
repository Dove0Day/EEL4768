`timescale 1ns/1ps
`default_nettype none

// Phase 6 hart testbench for the supplied 36,088-word random program.
// The program may branch or jump, so retirement is checked against the word
// stored at each retired PC rather than against a linear PC sequence.
// Each line in the input file is one 32-bit instruction word.
//
// Example:
//   iverilog -g2012 -Wall -Wno-timescale -s hart_random_tb \
//     -o hart_random_sim hart_random_tb.v hart.v cache.v decoder.v imm.v rf.v alu.v fpu.v
//   vvp hart_random_sim +PROGRAM=random_program.hex +COUNT=36088 +MAX_CYCLES=2000000 | tee actual_trace.txt
module hart_random_tb;
    localparam BLOCK_SIZE   = 16;
    localparam MEM_BYTES    = 262144;
    localparam MAX_WORDS    = MEM_BYTES / 4;
    localparam DEFAULT_COUNT = 36088;
    localparam DEFAULT_MAX_CYCLES = 2000000;

    reg i_clk;
    reg i_rst;

    wire o_imem_rd;
    wire [31:0] o_imem_rd_addr;
    reg i_imem_valid;
    reg [BLOCK_SIZE*8-1:0] i_imem_rd_data;

    wire o_dmem_rd;
    wire [31:0] o_dmem_rd_addr;
    reg i_dmem_valid;
    reg [BLOCK_SIZE*8-1:0] i_dmem_rd_data;
    wire o_dmem_wr;
    wire [31:0] o_dmem_wr_addr;
    wire [BLOCK_SIZE*8-1:0] o_dmem_wr_data;
    wire [BLOCK_SIZE-1:0] o_dmem_wr_be;

    wire o_retire_valid;
    wire [31:0] o_retire_inst;
    wire o_retire_trap;
    wire o_retire_halt;
    wire [4:0] o_retire_rs1_raddr;
    wire [4:0] o_retire_rs2_raddr;
    wire [31:0] o_retire_rs1_rdata;
    wire [31:0] o_retire_rs2_rdata;
    wire [4:0] o_retire_rd_waddr;
    wire [31:0] o_retire_rd_wdata;
    wire [31:0] o_retire_dmem_addr;
    wire [3:0] o_retire_dmem_mask;
    wire o_retire_dmem_ren;
    wire o_retire_dmem_wen;
    wire [31:0] o_retire_dmem_rdata;
    wire [31:0] o_retire_dmem_wdata;
    wire [31:0] o_retire_pc;
    wire [31:0] o_retire_next_pc;
    wire [4:0] o_retire_frs1_raddr;
    wire [31:0] o_retire_frs1_rdata;
    wire [4:0] o_retire_frs2_raddr;
    wire [31:0] o_retire_frs2_rdata;
    wire [4:0] o_retire_frs3_raddr;
    wire [31:0] o_retire_frs3_rdata;
    wire o_retire_frd_wen;
    wire [4:0] o_retire_frd_waddr;
    wire [31:0] o_retire_frd_wdata;
    wire [4:0] o_retire_fflags;

    reg [31:0] program_words [0:MAX_WORDS-1];
    reg [7:0] memory [0:MEM_BYTES-1];

    reg imem_pending;
    reg dmem_pending;
    reg [31:0] imem_pending_addr;
    reg [31:0] dmem_pending_addr;
    reg [2:0] imem_delay;
    reg [2:0] dmem_delay;

    reg [1023:0] program_file;
    integer program_count;
    integer max_cycles;
    integer retired;
    integer cycles;
    integer failures;
    integer k;

    hart #(
        .RESET_ADDR(32'h00000000),
        .FWD_EN(1),
        .BYPASS_EN(1),
        .EVICT_POLICY(0),
        .NUM_WAYS(1),
        .CACHE_SIZE(1),
        .BLOCK_SIZE(BLOCK_SIZE),
        .PREFETCH_EN(0)
    ) dut (
        .i_clk(i_clk), .i_rst(i_rst),
        .o_imem_rd(o_imem_rd), .o_imem_rd_addr(o_imem_rd_addr),
        .i_imem_valid(i_imem_valid), .i_imem_rd_data(i_imem_rd_data),
        .o_dmem_rd(o_dmem_rd), .o_dmem_rd_addr(o_dmem_rd_addr),
        .i_dmem_valid(i_dmem_valid), .i_dmem_rd_data(i_dmem_rd_data),
        .o_dmem_wr(o_dmem_wr), .o_dmem_wr_addr(o_dmem_wr_addr),
        .o_dmem_wr_data(o_dmem_wr_data), .o_dmem_wr_be(o_dmem_wr_be),
        .o_retire_valid(o_retire_valid), .o_retire_inst(o_retire_inst),
        .o_retire_trap(o_retire_trap), .o_retire_halt(o_retire_halt),
        .o_retire_rs1_raddr(o_retire_rs1_raddr),
        .o_retire_rs2_raddr(o_retire_rs2_raddr),
        .o_retire_rs1_rdata(o_retire_rs1_rdata),
        .o_retire_rs2_rdata(o_retire_rs2_rdata),
        .o_retire_rd_waddr(o_retire_rd_waddr),
        .o_retire_rd_wdata(o_retire_rd_wdata),
        .o_retire_dmem_addr(o_retire_dmem_addr),
        .o_retire_dmem_mask(o_retire_dmem_mask),
        .o_retire_dmem_ren(o_retire_dmem_ren),
        .o_retire_dmem_wen(o_retire_dmem_wen),
        .o_retire_dmem_rdata(o_retire_dmem_rdata),
        .o_retire_dmem_wdata(o_retire_dmem_wdata),
        .o_retire_pc(o_retire_pc), .o_retire_next_pc(o_retire_next_pc),
        .o_retire_frs1_raddr(o_retire_frs1_raddr),
        .o_retire_frs1_rdata(o_retire_frs1_rdata),
        .o_retire_frs2_raddr(o_retire_frs2_raddr),
        .o_retire_frs2_rdata(o_retire_frs2_rdata),
        .o_retire_frs3_raddr(o_retire_frs3_raddr),
        .o_retire_frs3_rdata(o_retire_frs3_rdata),
        .o_retire_frd_wen(o_retire_frd_wen),
        .o_retire_frd_waddr(o_retire_frd_waddr),
        .o_retire_frd_wdata(o_retire_frd_wdata),
        .o_retire_fflags(o_retire_fflags)
    );

    always #5 i_clk = ~i_clk;

    // Three-cycle backing-memory latency exercises cache/pipeline stalls.
    always @(posedge i_clk) begin
        i_imem_valid <= 1'b0;
        i_dmem_valid <= 1'b0;

        if (imem_pending) begin
            if (imem_delay == 3'd0) begin
                for (k=0; k<BLOCK_SIZE; k=k+1)
                    i_imem_rd_data[k*8 +: 8] <=
                        memory[(imem_pending_addr+k) % MEM_BYTES];
                i_imem_valid <= 1'b1;
                imem_pending <= 1'b0;
            end else begin
                imem_delay <= imem_delay - 3'd1;
            end
        end else if (o_imem_rd) begin
            imem_pending <= 1'b1;
            imem_pending_addr <= o_imem_rd_addr;
            imem_delay <= 3'd2;
        end

        if (dmem_pending) begin
            if (dmem_delay == 3'd0) begin
                for (k=0; k<BLOCK_SIZE; k=k+1)
                    i_dmem_rd_data[k*8 +: 8] <=
                        memory[(dmem_pending_addr+k) % MEM_BYTES];
                i_dmem_valid <= 1'b1;
                dmem_pending <= 1'b0;
            end else begin
                dmem_delay <= dmem_delay - 3'd1;
            end
        end else if (o_dmem_rd) begin
            dmem_pending <= 1'b1;
            dmem_pending_addr <= o_dmem_rd_addr;
            dmem_delay <= 3'd2;
        end

        if (o_dmem_wr) begin
            for (k=0; k<BLOCK_SIZE; k=k+1)
                if (o_dmem_wr_be[k])
                    memory[(o_dmem_wr_addr+k) % MEM_BYTES] <=
                        o_dmem_wr_data[k*8 +: 8];
        end
    end

    // Print and sanity-check every retired instruction.
    always @(posedge i_clk) begin
        if (!i_rst && o_retire_valid) begin
            retired = retired + 1;

            $display(
                "RETIRE %0d pc=%08x next=%08x inst=%08x trap=%b halt=%b rs1=%0d:%08x rs2=%0d:%08x rd=%0d:%08x frs1=%0d:%08x frs2=%0d:%08x frs3=%0d:%08x frd=%b/%0d:%08x memR=%b memW=%b addr=%08x mask=%x rdata=%08x wdata=%08x flags=%02x",
                retired, o_retire_pc, o_retire_next_pc, o_retire_inst,
                o_retire_trap, o_retire_halt,
                o_retire_rs1_raddr, o_retire_rs1_rdata,
                o_retire_rs2_raddr, o_retire_rs2_rdata,
                o_retire_rd_waddr, o_retire_rd_wdata,
                o_retire_frs1_raddr, o_retire_frs1_rdata,
                o_retire_frs2_raddr, o_retire_frs2_rdata,
                o_retire_frs3_raddr, o_retire_frs3_rdata,
                o_retire_frd_wen, o_retire_frd_waddr, o_retire_frd_wdata,
                o_retire_dmem_ren, o_retire_dmem_wen,
                o_retire_dmem_addr, o_retire_dmem_mask,
                o_retire_dmem_rdata, o_retire_dmem_wdata,
                o_retire_fflags
            );

            // The random image may branch and jump, so retirement order is
            // not required to be linear. Instead, verify alignment, range,
            // and that the retired instruction matches the loaded word at PC.
            if (o_retire_pc[1:0] !== 2'b00) begin
                failures = failures + 1;
                $display("FAIL misaligned retire PC=%08x", o_retire_pc);
            end

            if (o_retire_pc >= (program_count*4)) begin
                failures = failures + 1;
                $display("FAIL retire PC outside loaded image: pc=%08x limit=%08x",
                    o_retire_pc, program_count*4);
            end else if (o_retire_inst !== program_words[o_retire_pc[31:2]]) begin
                failures = failures + 1;
                $display("FAIL instruction at pc=%08x expected=%08x actual=%08x",
                    o_retire_pc, program_words[o_retire_pc[31:2]], o_retire_inst);
            end

            // A halt is an expected termination. A non-halt trap is reported,
            // but the testbench continues so the complete trace is preserved.
            if (o_retire_trap && !o_retire_halt) begin
                failures = failures + 1;
                $display("FAIL unexpected trap at pc=%08x inst=%08x",
                    o_retire_pc, o_retire_inst);
            end

            if (o_retire_halt || retired == program_count) begin
                $display("\nProgram complete: retired=%0d cycles=%0d failures=%0d halt=%b",
                    retired, cycles, failures, o_retire_halt);
                if (!o_retire_halt)
                    $display("NOTE: stopped at COUNT=%0d before a halt retired", program_count);
                if (failures != 0)
                    $fatal(1,"RANDOM PROGRAM TEST FAILED");
                $display("RANDOM PROGRAM TEST PASSED");
                $finish;
            end
        end
    end

    initial begin
        i_clk = 1'b0;
        i_rst = 1'b1;
        i_imem_valid = 1'b0;
        i_dmem_valid = 1'b0;
        i_imem_rd_data = {BLOCK_SIZE*8{1'b0}};
        i_dmem_rd_data = {BLOCK_SIZE*8{1'b0}};
        imem_pending = 1'b0;
        dmem_pending = 1'b0;
        imem_pending_addr = 32'd0;
        dmem_pending_addr = 32'd0;
        imem_delay = 3'd0;
        dmem_delay = 3'd0;
        retired = 0;
        cycles = 0;
        failures = 0;

        program_file = "random_program.hex";
        program_count = DEFAULT_COUNT;
        max_cycles = DEFAULT_MAX_CYCLES;
        if ($value$plusargs("PROGRAM=%s", program_file)) begin end
        if ($value$plusargs("COUNT=%d", program_count)) begin end
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin end

        for (k=0; k<MEM_BYTES; k=k+1)
            memory[k] = 8'h00;
        for (k=0; k<MAX_WORDS; k=k+1)
            program_words[k] = 32'h00000013;

        $display("Loading %0s (%0d instruction words)",
            program_file, program_count);
        $readmemh(program_file, program_words);

        // Convert word-per-line image to little-endian byte memory.
        for (k=0; k<program_count; k=k+1) begin
            memory[k*4+0] = program_words[k][7:0];
            memory[k*4+1] = program_words[k][15:8];
            memory[k*4+2] = program_words[k][23:16];
            memory[k*4+3] = program_words[k][31:24];
        end

        repeat (4) @(posedge i_clk);
        #1 i_rst = 1'b0;

        while (cycles < max_cycles) begin
            @(posedge i_clk);
            cycles = cycles + 1;
        end

        $fatal(1,"RANDOM PROGRAM TIMEOUT: retired %0d of %0d after %0d cycles",
            retired, program_count, cycles);
    end
endmodule

`default_nettype wire
