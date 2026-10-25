`default_nettype none

// The register file is effectively a single cycle memory with 32-bit words
// and depth 32. It has two asynchronous read ports, allowing two independent
// registers to be read at the same time combinationally, and one synchronous
// write port, allowing a register to be written to on the next clock edge.
//
// The register `x0` is hardwired to zero.
// NOTE: This can be implemented either by silently discarding writesto
// address 5'd0, or by muxing the output to zero when reading from that
// address.
module rf #(
    // When this parameter is set to 1, "RF bypass" mode is enabled. This
    // allows data at the write port to be observed at the read ports
    // immediately without having to wait for the next clock edge. This is
    // a common forwarding optimization in a pipelined core (phase 5), but will
    // cause a single-cycle processor to behave incorrectly. You are required
    // to implement and test both modes. In phase 4, you will disable this
    // parameter, before enabling it in phase 6.
    parameter BYPASS_EN = 0
) (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Both read register ports are asynchronous (zero-cycle). That is, read
    // data is visible combinationally without having to wait for a clock.
    //
    // The read ports are *independent* and can read two different registers
    // (but of course, also the same register if needed).
    //
    // Register `x0` is hardwired to zero, so reading from address 5'd0
    // should always return 32'd0 on either port regardless of any writes.
    //
    // Register read port 1, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs1_raddr,
    output wire [31:0] o_rs1_rdata,
    // Register read port 2, with input address [0, 31] and output data.
    input  wire [ 4:0] i_rs2_raddr,
    output wire [31:0] o_rs2_rdata,
    // The register write port is synchronous. When write is enabled, the
    // data at the write port will be written to the specified register
    // at the next clock edge. When the writen enable is low, the register
    // file should remain unchanged at the clock edge.
    //
    // Write register address [0, 31] and input data.
    input  wire [ 4:0] i_rd_waddr,
    input  wire [31:0] i_rd_wdata
);

    // 32 registers, 32 bits wide
    reg [31:0] registers [31:0];

    // Synchronous write & reset logic
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : reg_gen
            always @(posedge i_clk) begin
                if (i_rst)
                    registers[g] <= 32'b0;
                else if ((g != 0) && (i_rd_waddr == g))
                    registers[g] <= i_rd_wdata;
            end
        end
    endgenerate

    // Combinational read logic with x0 hardwired to zero
    wire [31:0] rs1_raw_data = (i_rs1_raddr == 5'd0) ? 32'h0000_0000 : registers[i_rs1_raddr];
    wire [31:0] rs2_raw_data = (i_rs2_raddr == 5'd0) ? 32'h0000_0000 : registers[i_rs2_raddr];

    // Optional Bypass logic (Active when BYPASS_EN = 1)
    wire bypass_rs1 = (BYPASS_EN != 0) && (i_rd_waddr != 5'd0) && (i_rs1_raddr == i_rd_waddr);
    wire bypass_rs2 = (BYPASS_EN != 0) && (i_rd_waddr != 5'd0) && (i_rs2_raddr == i_rd_waddr);

    assign o_rs1_rdata = bypass_rs1 ? i_rd_wdata : rs1_raw_data;
    assign o_rs2_rdata = bypass_rs2 ? i_rd_wdata : rs2_raw_data;

endmodule

`default_nettype wire
