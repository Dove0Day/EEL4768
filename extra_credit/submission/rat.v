`default_nettype none

// register alias table: tracks which ROB tag will write each register
// instantiated twice: integer (ZERO_REG = 1) and FP (ZERO_REG = 0)
module rat #(
    // ROB tag width (8 entry ROB)
    parameter TAG_W    = 3,
    // 1 = register 0 is hardwired to zero (integer), 0 = normal register (FP)
    parameter ZERO_REG = 1
) (
    input  wire             i_clk,
    input  wire             i_rst,

    // source lookups at issue
    input  wire [4:0]       i_rs1_addr,
    output wire             o_rs1_busy,
    output wire [TAG_W-1:0] o_rs1_tag,
    input  wire [4:0]       i_rs2_addr,
    output wire             o_rs2_busy,
    output wire [TAG_W-1:0] o_rs2_tag,
    input  wire [4:0]       i_rs3_addr,
    output wire             o_rs3_busy,
    output wire [TAG_W-1:0] o_rs3_tag,

    // rename destination at issue
    input  wire             i_rename_en,
    input  wire [4:0]       i_rename_rd,
    input  wire [TAG_W-1:0] i_rename_tag,

    // register write committed from ROB head
    input  wire             i_commit_en,
    input  wire [4:0]       i_commit_rd,
    input  wire [TAG_W-1:0] i_commit_tag,

    // clear whole table (tie to 0 if unused)
    input  wire             i_flush,

    // checkpoint of the table: save at issue of a speculative branch,
    // restore on a mispredict (tie both to 0 if unused)
    input  wire             i_ckpt_save,
    input  wire             i_ckpt_restore,

    // busy bit for every register (debug / FV)
    output wire [31:0]      o_busy
);

    // busy bits are reset, tags only matter while busy
    reg  [31:0]      busy_q;
    reg  [TAG_W-1:0] tag_q [0:31];

    // x0 is never renamed in the integer RAT
    wire rename_ok;
    assign rename_ok = i_rename_en &&
                       !((ZERO_REG != 0) && (i_rename_rd == 5'd0));

    // commit only clears if no younger instruction renamed the register
    wire commit_match;
    assign commit_match = i_commit_en &&
                          busy_q[i_commit_rd] &&
                          (tag_q[i_commit_rd] == i_commit_tag);

    // next busy bits: flush clears, rename sets (wins over commit), commit clears
    wire [31:0] busy_next;

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_busy
            wire rename_here;
            wire commit_here;

            assign rename_here = rename_ok && (i_rename_rd == g);
            assign commit_here = commit_match && (i_commit_rd == g);

            assign busy_next[g] = i_flush     ? 1'b0 :
                                  rename_here ? 1'b1 :
                                  commit_here ? 1'b0 :
                                                busy_q[g];
        end
    endgenerate

    // checkpoint: older instructions keep committing after the save, so the
    // checkpoint also drops busy bits whose producer commits
    reg  [31:0]      ckpt_busy_q;
    reg  [TAG_W-1:0] ckpt_tag_q [0:31];
    wire [31:0]      ckpt_busy_commit;

    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_ckpt
            assign ckpt_busy_commit[g] = ckpt_busy_q[g] &&
                !(i_commit_en && (i_commit_rd == g) && (ckpt_tag_q[g] == i_commit_tag));
        end
    endgenerate

    // Checkpoint busy-bit update
    always @(posedge i_clk) begin
        if (i_rst) begin
            ckpt_busy_q <= 32'b0;
        end
        else if (i_ckpt_save) begin
            ckpt_busy_q <= busy_next;
        end
        else begin
            ckpt_busy_q <= ckpt_busy_commit;
        end
    end

    // Active RAT busy-bit update
    always @(posedge i_clk) begin
        if (i_rst) begin
            busy_q <= 32'b0;
        end
        else begin
            busy_q <= i_ckpt_restore ?
                      ckpt_busy_commit : busy_next;
        end
    end

    // Per-register tag save, rename and restore
    genvar k;
    generate
        for (k = 0; k < 32; k = k + 1) begin : gen_tags

            wire rename_here;

            assign rename_here = rename_ok &&
                                 (i_rename_rd == k[4:0]);

            always @(posedge i_clk) begin
                if (!i_rst && i_ckpt_save) begin
                    ckpt_tag_q[k] <= rename_here ?
                                     i_rename_tag : tag_q[k];
                end
            end

            always @(posedge i_clk) begin
                if (!i_rst) begin
                    if (i_ckpt_restore) begin
                        tag_q[k] <= ckpt_tag_q[k];
                    end
                    else if (rename_here && !i_flush) begin
                        tag_q[k] <= i_rename_tag;
                    end
                end
            end

        end
    endgenerate

    // lookups show the table from the start of the cycle
    // (add x1, x1, x2 sees the older producer of x1)
    wire rs1_zero;
    wire rs2_zero;
    wire rs3_zero;
    assign rs1_zero = (ZERO_REG != 0) && (i_rs1_addr == 5'd0);
    assign rs2_zero = (ZERO_REG != 0) && (i_rs2_addr == 5'd0);
    assign rs3_zero = (ZERO_REG != 0) && (i_rs3_addr == 5'd0);

    assign o_rs1_busy = !rs1_zero && busy_q[i_rs1_addr];
    assign o_rs2_busy = !rs2_zero && busy_q[i_rs2_addr];
    assign o_rs3_busy = !rs3_zero && busy_q[i_rs3_addr];

    // tag reads 0 when not busy
    assign o_rs1_tag = o_rs1_busy ? tag_q[i_rs1_addr] : {TAG_W{1'b0}};
    assign o_rs2_tag = o_rs2_busy ? tag_q[i_rs2_addr] : {TAG_W{1'b0}};
    assign o_rs3_tag = o_rs3_busy ? tag_q[i_rs3_addr] : {TAG_W{1'b0}};

    assign o_busy = busy_q;

endmodule

`default_nettype wire
