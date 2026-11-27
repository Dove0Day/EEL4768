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
  // Instantiate YOUR modules (names must match your submitted .v files).
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

  localparam TAG_W = 3;

  (* anyseq *) reg [TAG_W-1:0] i_rob_head;
  (* anyseq *) reg             i_int_v;
  (* anyseq *) reg [TAG_W-1:0] i_int_tag;
  (* anyseq *) reg [31:0]      i_int_value;
  (* anyseq *) reg             i_ld_v;
  (* anyseq *) reg [TAG_W-1:0] i_ld_tag;
  (* anyseq *) reg [31:0]      i_ld_value;

  (* anyseq *) reg             i_fp0_v;
  (* anyseq *) reg [TAG_W-1:0] i_fp0_tag;
  (* anyseq *) reg [31:0]      i_fp0_value;
  wire             o_fp0_grant;

  (* anyseq *) reg             i_fp1_v;
  (* anyseq *) reg [TAG_W-1:0] i_fp1_tag;
  (* anyseq *) reg [31:0]      i_fp1_value;
  wire             o_fp1_grant;

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
    .i_fp0_v(i_fp0_v),
    .i_fp0_tag(i_fp0_tag),
    .i_fp0_value(i_fp0_value),
    .o_fp0_grant(o_fp0_grant),
    .i_fp1_v(i_fp1_v),
    .i_fp1_tag(i_fp1_tag),
    .i_fp1_value(i_fp1_value),
    .o_fp1_grant(o_fp1_grant),
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

  (* anyseq *) reg [4:0]       i_rs3;
  (* anyseq *) reg             i_commit_en;
  (* anyseq *) reg [4:0]       i_commit_rd;
  (* anyseq *) reg [TAG_W-1:0] i_commit_tag;
  (* anyseq *) reg             i_flush;
  wire [31:0] o_busy;
  wire o_rs3_busy;
  wire [TAG_W-1:0] o_rs3_tag;

  wire             o_rs1_busy;
  wire [TAG_W-1:0] o_rs1_tag;
  wire             o_rs2_busy;
  wire [TAG_W-1:0] o_rs2_tag;

  rat #(.TAG_W(TAG_W)) dut_rat (
    .i_clk(i_clk),
    .i_rst(i_rst),
    .i_rename_en(i_alloc_v),
    .i_rename_rd(i_alloc_rd),
    .i_rename_tag(i_alloc_tag),
    .i_commit_en(i_commit_en),
    .i_commit_rd(i_commit_rd),
    .i_commit_tag(i_commit_tag),
    .i_flush(i_flush),
    .o_busy(o_busy),
    .i_rs3_addr(i_rs3),
    .o_rs3_busy(o_rs3_busy),
    .o_rs3_tag(o_rs3_tag),
    .i_rs1_addr(i_rs1),
    .i_rs2_addr(i_rs2),
    .o_rs1_busy(o_rs1_busy),
    .o_rs1_tag(o_rs1_tag),
    .o_rs2_busy(o_rs2_busy),
    .o_rs2_tag(o_rs2_tag),
    .i_ckpt_save    (1'b0),
    .i_ckpt_restore (1'b0)
  );

`ifdef FORMAL
  // Assume / assert about the instantiated DUT.
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

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk)
    f_past_valid <= 1'b1;

  initial assume(i_rst);

  wire [TAG_W-1:0] int_age = i_int_tag - i_rob_head;
  wire [TAG_W-1:0] fp0_age = i_fp0_tag - i_rob_head;
  wire [TAG_W-1:0] fp1_age = i_fp1_tag - i_rob_head;
  wire [TAG_W-1:0] ld_age = i_ld_tag - i_rob_head;

  always @(*) begin
    if (!i_rst) begin
      assert (!(o_int_grant && o_fp0_grant));
      assert (!(o_int_grant && o_fp1_grant));
      assert (!(o_int_grant && o_ld_grant));
      assert (!o_int_grant || i_int_v);
      if (o_int_grant) begin
        assert (o_cdb_tag == i_int_tag);
        assert (o_cdb_value == i_int_value);
        assert (!i_fp0_v || (int_age <= fp0_age));
        assert (!i_fp1_v || (int_age <= fp1_age));
        assert (!i_ld_v || (int_age <= ld_age));
      end
      assert (!(o_fp0_grant && o_fp1_grant));
      assert (!(o_fp0_grant && o_ld_grant));
      assert (!o_fp0_grant || i_fp0_v);
      if (o_fp0_grant) begin
        assert (o_cdb_tag == i_fp0_tag);
        assert (o_cdb_value == i_fp0_value);
        assert (!i_int_v || (fp0_age < int_age));
        assert (!i_fp1_v || (fp0_age <= fp1_age));
        assert (!i_ld_v || (fp0_age <= ld_age));
      end
      assert (!(o_fp1_grant && o_ld_grant));
      assert (!o_fp1_grant || i_fp1_v);
      if (o_fp1_grant) begin
        assert (o_cdb_tag == i_fp1_tag);
        assert (o_cdb_value == i_fp1_value);
        assert (!i_int_v || (fp1_age < int_age));
        assert (!i_fp0_v || (fp1_age < fp0_age));
        assert (!i_ld_v || (fp1_age <= ld_age));
      end
      assert (!o_ld_grant || i_ld_v);
      if (o_ld_grant) begin
        assert (o_cdb_tag == i_ld_tag);
        assert (o_cdb_value == i_ld_value);
        assert (!i_int_v || (ld_age < int_age));
        assert (!i_fp0_v || (ld_age < fp0_age));
        assert (!i_fp1_v || (ld_age < fp1_age));
      end
      assert (o_cdb_valid == (o_int_grant || o_fp0_grant || o_fp1_grant || o_ld_grant));
      assert (o_cdb_valid == (i_int_v || i_fp0_v || i_fp1_v || i_ld_v));
    end
  end

  // Independent arbitrary lookup addresses; check only initialized state.
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      assert (!o_busy[0]);
      assert (o_rs1_busy == o_busy[i_rs1]);
      assert (o_rs1_busy || (o_rs1_tag == 3'd0));
      assert (o_rs2_busy == o_busy[i_rs2]);
      assert (o_rs2_busy || (o_rs2_tag == 3'd0));
      assert (o_rs3_busy == o_busy[i_rs3]);
      assert (o_rs3_busy || (o_rs3_tag == 3'd0));
      if (i_rs1 == i_rs2) begin
        assert (o_rs1_busy == o_rs2_busy);
        assert (o_rs1_tag == o_rs2_tag);
      end
      if (i_rs1 == i_rs3) begin
        assert (o_rs1_busy == o_rs3_busy);
        assert (o_rs1_tag == o_rs3_tag);
      end
      if (i_rs2 == i_rs3) begin
        assert (o_rs2_busy == o_rs3_busy);
        assert (o_rs2_tag == o_rs3_tag);
      end
      if ($past(i_rst || i_flush)) begin
        assert (o_busy == 32'b0);
      end else begin
        if ($past(i_alloc_v) && ($past(i_alloc_rd) != 5'd0)) begin
          assert (o_busy[$past(i_alloc_rd)]);
          if (i_rs1 == $past(i_alloc_rd))
            assert (o_rs1_tag == $past(i_alloc_tag));
        end
        // Compare the same register across cycles; rename wins over commit.
        if (i_rs1 == $past(i_rs1) &&
            !($past(i_alloc_v) && ($past(i_alloc_rd) == i_rs1) && (i_rs1 != 5'd0))) begin
          if ($past(i_commit_en) && ($past(i_commit_rd) == i_rs1) &&
              $past(o_rs1_busy) && ($past(o_rs1_tag) == $past(i_commit_tag))) begin
            assert (!o_rs1_busy);
          end else begin
            assert (o_rs1_busy == $past(o_rs1_busy));
            assert (o_rs1_tag == $past(o_rs1_tag));
          end
        end
      end
    end
  end
`endif
endmodule
`default_nettype wire