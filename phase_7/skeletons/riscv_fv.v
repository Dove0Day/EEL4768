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

  // Added implementation. The original skeleton above is unchanged.
  localparam TAG_W = 3;

  (* anyseq *) reg [TAG_W-1:0] i_rob_head;
  (* anyseq *) reg             i_int_v;
  (* anyseq *) reg [TAG_W-1:0] i_int_tag;
  (* anyseq *) reg [31:0]      i_int_value;
  (* anyseq *) reg             i_ld_v;
  (* anyseq *) reg [TAG_W-1:0] i_ld_tag;
  (* anyseq *) reg [31:0]      i_ld_value;

  wire             o_int_grant;
  wire             o_ld_grant;
  wire             o_cdb_valid;
  wire [TAG_W-1:0] o_cdb_tag;
  wire [31:0]      o_cdb_value;

  cdb_arb #(.TAG_W(TAG_W)) dut_cdb (
    .i_rob_head(i_rob_head),
    .i_int_v(i_int_v),
    .i_int_tag(i_int_tag),
    .i_int_value(i_int_value),
    .i_ld_v(i_ld_v),
    .i_ld_tag(i_ld_tag),
    .i_ld_value(i_ld_value),
    .o_int_grant(o_int_grant),
    .o_ld_grant(o_ld_grant),
    .o_cdb_valid(o_cdb_valid),
    .o_cdb_tag(o_cdb_tag),
    .o_cdb_value(o_cdb_value)
  );

  (* anyseq *) reg             i_alloc_v;
  (* anyseq *) reg [4:0]       i_alloc_rd;
  (* anyseq *) reg [TAG_W-1:0] i_alloc_tag;
  (* anyseq *) reg [4:0]       i_rs1;
  (* anyseq *) reg [4:0]       i_rs2;

  wire             o_rs1_busy;
  wire [TAG_W-1:0] o_rs1_tag;
  wire             o_rs2_busy;
  wire [TAG_W-1:0] o_rs2_tag;

  rat #(.TAG_W(TAG_W)) dut_rat (
    .i_clk(i_clk),
    .i_rst(i_rst),
    .i_alloc_v(i_alloc_v),
    .i_alloc_rd(i_alloc_rd),
    .i_alloc_tag(i_alloc_tag),
    .i_cdb_v(o_cdb_valid),
    .i_cdb_tag(o_cdb_tag),
    .i_rs1(i_rs1),
    .i_rs2(i_rs2),
    .o_rs1_busy(o_rs1_busy),
    .o_rs1_tag(o_rs1_tag),
    .o_rs2_busy(o_rs2_busy),
    .o_rs2_tag(o_rs2_tag)
  );

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

  // Added formal properties. The original skeleton above is unchanged.
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk)
    f_past_valid <= 1'b1;

  initial assume(i_rst);

  always @(*) begin
    if (!i_rst) begin
      assert (!(o_int_grant && o_ld_grant));
      assert (!o_int_grant || i_int_v);
      assert (!o_ld_grant || i_ld_v);
      assert (o_cdb_valid == (o_int_grant || o_ld_grant));
      assert (!(i_int_v || i_ld_v) || o_cdb_valid);

      if (o_int_grant) begin
        assert (o_cdb_tag == i_int_tag);
        assert (o_cdb_value == i_int_value);
      end

      if (o_ld_grant) begin
        assert (o_cdb_tag == i_ld_tag);
        assert (o_cdb_value == i_ld_value);
      end

      if (i_int_v && !i_ld_v)
        assert (o_int_grant && !o_ld_grant);

      if (i_ld_v && !i_int_v)
        assert (o_ld_grant && !o_int_grant);

      if (!i_int_v && !i_ld_v)
        assert (!o_cdb_valid);

      if (i_rs1 == i_rs2) begin
        assert (o_rs1_busy == o_rs2_busy);
        if (o_rs1_busy)
          assert (o_rs1_tag == o_rs2_tag);
      end

      if (i_rs1 == 5'd0)
        assert (!o_rs1_busy);
      if (i_rs2 == 5'd0)
        assert (!o_rs2_busy);
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && $past(i_rst)) begin
      assert (!o_rs1_busy);
      assert (!o_rs2_busy);
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !$past(i_rst) &&
        $past(i_alloc_v) && ($past(i_alloc_rd) != 5'd0) &&
        ($past(i_alloc_rd) == $past(i_rs1)) &&
        !($past(o_cdb_valid) &&
          ($past(o_cdb_tag) == $past(i_alloc_tag)))) begin
      assert (o_rs1_busy);
      assert (o_rs1_tag == $past(i_alloc_tag));
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !$past(i_rst) &&
        $past(o_rs1_busy) && $past(o_cdb_valid) &&
        ($past(o_rs1_tag) == $past(o_cdb_tag)) &&
        !($past(i_alloc_v) &&
          ($past(i_alloc_rd) != 5'd0) &&
          ($past(i_alloc_rd) == $past(i_rs1)))) begin
      assert (!o_rs1_busy);
    end
  end
`endif
endmodule
`default_nettype wire
