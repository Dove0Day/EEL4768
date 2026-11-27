`default_nettype none

// Select oldest ready CDB producer relative to current ROB head
// TAG_W=3 matches Phase 7 eight-entry ROB
// FP inputs represent results from FP lanes
module cdb_arb #(
    parameter TAG_W = 3
) (
    input  wire [TAG_W-1:0] i_rob_head,

    input  wire             i_int_v,
    input  wire [TAG_W-1:0] i_int_tag,
    input  wire [31:0]      i_int_value,

    input  wire             i_fp0_v,
    input  wire [TAG_W-1:0] i_fp0_tag,
    input  wire [31:0]      i_fp0_value,

    input  wire             i_fp1_v,
    input  wire [TAG_W-1:0] i_fp1_tag,
    input  wire [31:0]      i_fp1_value,

    input  wire             i_ld_v,
    input  wire [TAG_W-1:0] i_ld_tag,
    input  wire [31:0]      i_ld_value,

    output wire             o_int_grant,
    output wire             o_fp0_grant,
    output wire             o_fp1_grant,
    output wire             o_ld_grant,
    output wire             o_cdb_valid,
    output wire [TAG_W-1:0] o_cdb_tag,
    output wire [31:0]      o_cdb_value
);
    // compare relative ages instead of raw tags because the ROB is circular
    wire [TAG_W-1:0] int_age;
    wire [TAG_W-1:0] fp0_age;
    wire [TAG_W-1:0] fp1_age;
    wire [TAG_W-1:0] ld_age;
    wire             choose_int;
    wire             choose_fp0;
    wire             choose_fp1;
    wire             choose_ld;

    // ROB tags wrap mod 2**TAG_W
    //within live ROB window
    // smaller forward distance from head is older instruction
    assign int_age = i_int_tag - i_rob_head;
    assign fp0_age = i_fp0_tag - i_rob_head;
    assign fp1_age = i_fp1_tag - i_rob_head;
    assign ld_age  = i_ld_tag  - i_rob_head;

    // Equal tags resolved in fixed order: INT, FP lane 0, FP lane 1, load
    // at most one producer per ROB tag
    // a producer wins only if valid and no higher priority valid producer is older
    assign choose_int = i_int_v &&
                        (!i_fp0_v || (int_age <= fp0_age)) &&
                        (!i_fp1_v || (int_age <= fp1_age)) &&
                        (!i_ld_v  || (int_age <= ld_age));
    assign choose_fp0 = i_fp0_v &&
                        (!i_int_v || (fp0_age < int_age)) &&
                        (!i_fp1_v || (fp0_age <= fp1_age)) &&
                        (!i_ld_v  || (fp0_age <= ld_age));
    assign choose_fp1 = i_fp1_v &&
                        (!i_int_v || (fp1_age < int_age)) &&
                        (!i_fp0_v || (fp1_age < fp0_age)) &&
                        (!i_ld_v  || (fp1_age <= ld_age));
    assign choose_ld = i_ld_v &&
                       (!i_int_v || (ld_age < int_age)) &&
                       (!i_fp0_v || (ld_age < fp0_age)) &&
                       (!i_fp1_v || (ld_age < fp1_age));

    // grants tell the execution units which pending result can be released
    assign o_int_grant = choose_int;
    assign o_fp0_grant = choose_fp0;
    assign o_fp1_grant = choose_fp1;
    assign o_ld_grant  = choose_ld;
    assign o_cdb_valid = choose_int || choose_fp0 || choose_fp1 || choose_ld;
    // broadcast one tag/value pair, drive zero when no producer is selected
    assign o_cdb_tag   = choose_int ? i_int_tag :
                         choose_fp0 ? i_fp0_tag :
                         choose_fp1 ? i_fp1_tag :
                         choose_ld  ? i_ld_tag  : {TAG_W{1'b0}};
    assign o_cdb_value = choose_int ? i_int_value :
                         choose_fp0 ? i_fp0_value :
                         choose_fp1 ? i_fp1_value :
                         choose_ld  ? i_ld_value  : 32'b0;
endmodule

`default_nettype wire
