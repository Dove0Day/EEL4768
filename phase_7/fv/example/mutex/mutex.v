// Tiny mutual-exclusion example for the SymbiYosys smoke test.
// See the Formal Verification section of documentation/phase_7.pdf.
module mutex (
  input  wire clk,
  input  wire rst,
  input  wire req_a,
  input  wire req_b,
  output reg  gnt_a,
  output reg  gnt_b
);
  always @(posedge clk) begin
    if (rst) begin
      gnt_a <= 1'b0;
      gnt_b <= 1'b0;
    end else begin
      gnt_a <= req_a & ~req_b;
      gnt_b <= req_b & ~req_a;
    end
  end

`ifdef FORMAL
  always @(*) begin
    if (!rst)
      assert (!(gnt_a && gnt_b));
  end
`endif
endmodule
