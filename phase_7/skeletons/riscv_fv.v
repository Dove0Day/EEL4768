// Graded FV harness. Fill this in and submit as riscv_fv.v (submission root,
// next to hart.v). Module name must remain riscv_fv.
//
// The shipped riscv_fv.sby always compiles exactly:
//   riscv_fv.v  cdb_arb.v  rat.v
// Instantiate YOUR cdb_arb / rat here and write assume/assert properties that
// SymbiYosys (sby) reports as PASS. Learn the toolchain first with
// fv/example/mutex/.
//
// Self-check:
//   fv/riscv/run.sh /path/to/your/submission   (from phase_7/)
//
// Credit (PDF Sections 6.2, 7.7): at least 10 non-vacuous asserts using the assert keyword, and sby reports PASS.

`default_nettype none

module riscv_fv (
  input wire i_clk,
  input wire i_rst
  // Add ports you need to drive / observe, or keep DUT inputs free for BMC.
);

  // -------------------------------------------------------------------------
  // TODO: instantiate YOUR modules (names must match your submitted .v files).
  // Example shape (replace with your real ports / parameters):
  //
  //   wire        o_int_grant, o_ld_grant, o_cdb_valid;
  //   wire [2:0]  o_cdb_tag;
  //   wire [31:0] o_cdb_value;
  //
  //   cdb_arb #(.TAG_W(3)) dut_cdb (
  //     .i_rob_head(...),
  //     .i_int_v(...),
  //     ...
  //     .o_int_grant(o_int_grant),
  //     .o_ld_grant(o_ld_grant),
  //     .o_cdb_valid(o_cdb_valid),
  //     .o_cdb_tag(o_cdb_tag),
  //     .o_cdb_value(o_cdb_value)
  //   );
  //
  //   rat #(.TAG_W(3)) dut_rat (
  //     .i_clk(i_clk),
  //     .i_rst(i_rst),
  //     ...
  //   );
  // -------------------------------------------------------------------------

`ifdef FORMAL
  // TODO: add assume / assert about the instantiated DUT.
  // Need at least 10 assert keywords total. Examples:
  //
  //   always @(*) begin
  //     if (!i_rst)
  //       assert (!(o_int_grant && o_ld_grant));
  //   end
  //
  //   always @(posedge i_clk) begin
  //     if (!i_rst)
  //       assert (...);
  //   end
`endif
endmodule

`default_nettype wire
