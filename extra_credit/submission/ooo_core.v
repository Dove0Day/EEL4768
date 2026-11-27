`default_nettype none
module ooo_core (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_id_valid,
    input  wire [31:0] i_id_inst,
    input  wire [31:0] i_id_pc,
    // [BP] prediction made in IF, carried with the instruction
    input  wire        i_id_pred_taken,
    input  wire [31:0] i_id_pred_target,
    input  wire        i_dec_legal,
    input  wire        i_dec_halt,
    input  wire [4:0]  i_dec_rs1,
    input  wire [4:0]  i_dec_rs2,
    input  wire [4:0]  i_dec_rd,
    input  wire [31:0] i_dec_imm,
    input  wire        i_dec_op1_sel,
    input  wire        i_dec_op2_sel,
    input  wire [2:0]  i_dec_alu_opsel,
    input  wire        i_dec_alu_sub,
    input  wire        i_dec_alu_unsigned,
    input  wire        i_dec_alu_arith,
    input  wire        i_dec_branch,
    input  wire        i_dec_jump,
    input  wire        i_dec_branch_equal,
    input  wire        i_dec_branch_unsigned,
    input  wire        i_dec_branch_invert,
    input  wire        i_dec_pc_sel,
    input  wire        i_dec_dmem_ren,
    input  wire        i_dec_dmem_wen,
    input  wire        i_dec_dmem_memb,
    input  wire        i_dec_dmem_memh,
    input  wire        i_dec_dmem_memw,
    input  wire        i_dec_dmem_memu,
    input  wire [4:0]  i_dec_rd_sel,
    input  wire        i_dec_mext,
    input  wire        i_dec_fpu,
    input  wire        i_dec_frs1_en,
    input  wire        i_dec_frs2_en,
    input  wire        i_dec_frs3_en,
    input  wire        i_dec_frd_en,
    input  wire [4:0]  i_dec_frs1_addr,
    input  wire [4:0]  i_dec_frs2_addr,
    input  wire [4:0]  i_dec_frs3_addr,
    input  wire [31:0] i_rf_rs1_data,
    input  wire [31:0] i_rf_rs2_data,
    input  wire [31:0] i_rf_frs1_data,
    input  wire [31:0] i_rf_frs2_data,
    input  wire [31:0] i_rf_frs3_data,

    output wire         o_rf_wen,
    output wire  [4:0]  o_rf_waddr,
    output wire  [31:0] o_rf_wdata,
    output wire         o_frd_wen,
    output wire  [4:0]  o_frd_waddr,
    output wire  [31:0] o_frd_wdata,
    // [BP] o_taken now means "redirect": a misprediction (or an unpredicted
    // jump) was resolved; o_pc_jump is the CORRECT next pc
    output wire         o_taken,
    output wire  [31:0] o_pc_jump,
    output wire        o_id_hold,
    output wire        o_fetch_stall,
    // [BP] predictor update, one pulse per resolved conditional branch
    output wire         o_bp_upd_valid,
    output wire  [31:0] o_bp_upd_pc,
    output wire         o_bp_upd_taken,
    output wire  [31:0] o_bp_upd_target,

    output wire        o_dcache_ren,
    output wire        o_dcache_wen,
    output wire [31:0] o_dcache_addr,
    output wire [3:0]  o_dcache_mask,
    output wire [31:0] o_dcache_wdata,
    input  wire        i_dcache_ready,
    input  wire [31:0] i_dcache_rdata,

    output wire         o_retire_valid,
    output wire  [31:0] o_retire_inst,
    output wire         o_retire_trap,
    output wire         o_retire_halt,
    output wire  [4:0]  o_retire_rs1_raddr,
    output wire  [4:0]  o_retire_rs2_raddr,
    output wire  [31:0] o_retire_rs1_rdata,
    output wire  [31:0] o_retire_rs2_rdata,
    output wire  [4:0]  o_retire_rd_waddr,
    output wire  [31:0] o_retire_rd_wdata,
    output wire  [31:0] o_retire_dmem_addr,
    output wire  [3:0]  o_retire_dmem_mask,
    output wire         o_retire_dmem_ren,
    output wire         o_retire_dmem_wen,
    output wire  [31:0] o_retire_dmem_rdata,
    output wire  [31:0] o_retire_dmem_wdata,
    output wire  [31:0] o_retire_pc,
    output wire  [31:0] o_retire_next_pc,
    output wire  [4:0]  o_retire_frs1_raddr,
    output wire  [31:0] o_retire_frs1_rdata,
    output wire  [4:0]  o_retire_frs2_raddr,
    output wire  [31:0] o_retire_frs2_rdata,
    output wire  [4:0]  o_retire_frs3_raddr,
    output wire  [31:0] o_retire_frs3_rdata,
    output wire         o_retire_frd_wen,
    output wire  [4:0]  o_retire_frd_waddr,
    output wire  [31:0] o_retire_frd_wdata,
    output wire  [4:0]  o_retire_fflags,

    output wire         o_complete_valid,
    output wire  [2:0]  o_complete_tag,
    output wire  [4:0]  o_complete_rd,
    output wire  [31:0] o_complete_value,
    output wire  [31:0] o_complete_pc
);

    // ROB tags are circular indices. Queue membership is separate from completion.
    reg [2:0] head, tail;
    reg [3:0] count;
    // [BP] ctrl now only tracks an in-flight jump (jal/jalr); cbr_inflight tracks
    // the single unresolved (speculative) conditional branch
    reg ctrl;
    reg cbr_inflight;
    reg csr_barrier;
    reg [7:0] shared_fcsr;
    reg [31:0] committed_i[0:31], committed_f[0:31];
    // live tracks allocated ROB entries, done tracks completed instructions
    // irs/frs/lsu track entries still belonging to each execution queue
    reg [7:0] live, done, trap, halt, irs, frs, lsu, dispatched;
    reg [31:0] inst[0:7], pc[0:7], npc[0:7], imm[0:7], result[0:7];
    reg [4:0] rd[0:7], flags[0:7];
    reg [7:0] fw, iw, load, store, byteop, halfop, wordop, uns;
    reg [7:0] branch, jump, eqmode, bunsigned, invert, pcsel, op1, op2, subop, aluuns, arith, mext, lui;
    // [BP] per-entry prediction
    reg [7:0] ppred;
    reg [31:0] ptgt[0:7];
    reg [2:0] opcode[0:7];
    reg [31:0] memraw[0:7];
    // common data bus: valid, producer ROB tag and result value
    wire cv; wire [2:0] ct; wire [31:0] cd;
    wire commit, issue;
    wire mispred;   // [BP] a resolving branch/jump was mispredicted: flush younger
    wire [3:0] icount, fcount;
    // classify the incoming instruction before allocating a queue entry
    // illegal instructions and ebreak only need a ROB entry
    wire ismem = i_dec_dmem_ren || i_dec_dmem_wen;
    wire terminal = !i_dec_legal || i_dec_halt;
    wire isfp = i_dec_fpu && !ismem;
    wire wi = |i_dec_rd_sel && i_dec_rd != 0 && !terminal;
    wire wf = i_dec_frd_en && !terminal;
    reg [31:0] v0[0:7];
    // serialize CSR instructions so both FP lanes use the same architectural frm
    // compute the next fcsr from the instruction at the ROB head
    wire incoming_csr = i_id_inst[6:0] == 7'h73 && isfp && !terminal;
    wire head_csr = inst[head][6:0] == 7'h73 && !trap[head] && !halt[head];
    wire [31:0] csr_old = inst[head][31:20]==12'h001 ? {27'd0,shared_fcsr[4:0]} : inst[head][31:20]==12'h002 ? {29'd0,shared_fcsr[7:5]} : {24'd0,shared_fcsr};
    wire [31:0] csr_src = inst[head][14] ? {27'd0,inst[head][19:15]} : v0[head];
    wire [31:0] csr_new = inst[head][13:12]==2'b01 ? csr_src : inst[head][13:12]==2'b10 ? csr_old | csr_src : csr_old & ~csr_src;
    wire [7:0] next_fcsr = trap[head] ? shared_fcsr : head_csr ? (inst[head][31:20]==12'h001 ? {shared_fcsr[7:5],csr_new[4:0]} : inst[head][31:20]==12'h002 ? {csr_new[2:0],shared_fcsr[4:0]} : csr_new[7:0]) : {shared_fcsr[7:5],shared_fcsr[4:0] | flags[head]};
    // a trapped producer does not write its destination
    // use the last committed register value to release dependent instructions
    wire [31:0] trap_i_value = committed_i[rd[head]];
    wire [31:0] trap_f_value = committed_f[rd[head]];
    // keep a copy of the architectural register values for trap recovery
    genvar r; generate for(r=0;r<32;r=r+1) begin: committed_snapshot
      always @(posedge i_clk) begin
        if(i_rst) begin committed_i[r]<=0; committed_f[r]<=0; end
        else begin
          if(o_rf_wen && o_rf_waddr==r) committed_i[r]<=o_rf_wdata;
          if(o_frd_wen && o_frd_waddr==r) committed_f[r]<=o_frd_wdata;
        end
      end
    end endgenerate
    always @(posedge i_clk) begin
      if(i_rst) begin shared_fcsr<=0; csr_barrier<=0; end
      else begin
        if(commit) shared_fcsr<=next_fcsr;
        if(commit && head_csr) csr_barrier<=0;
        if(issue && incoming_csr) csr_barrier<=1;
        // [BP] a csr never issues behind an older in-flight csr (barrier), and
        // never ahead of an unresolved branch's resolution without being younger
        // than it, so any csr in flight at a flush is wrong-path: drop the barrier
        if(mispred) csr_barrier<=0;
      end
    end

    // [EBR+BP] Dedicated 1-entry branch/jump resolver (at most 1 unresolved branch
    // or jump can be in-flight because `ctrl` / `cbr_inflight` block a second one)
    reg br_valid;
    reg [2:0] br_tag;
    wire issue_ctrl = !terminal && (i_dec_branch || i_dec_jump);


    // [BP] jumps still serialize issue; a conditional branch only blocks issue of
    // a second control instruction while it is unresolved (one speculative branch)

    // [ERB] don't stall control ops on `icount == 4`

    assign o_id_hold = ctrl || csr_barrier || count == 8 ||
                       (cbr_inflight && !terminal && (i_dec_branch || i_dec_jump)) ||
                       (!terminal && !ismem && !issue_ctrl && (isfp ? fcount == 4 : icount == 4));
    assign o_fetch_stall = 1'b0;

    // [EBR+BP] Only block `issue` on an OLDER branch's mispredict (`mispred`), not an
    // issue-time redirect, to avoid a combinational loop
    assign issue = i_id_valid && !o_id_hold && !mispred && !i_rst;

    // integer rs1: use the CDB result first, then the ROB result or register file
    // keep the producer tag if the value is not ready yet
    wire busy0; wire [2:0] tag0;
    reg [4:0] addr0[0:7];
    reg [2:0] q0[0:7]; reg [7:0] wait0;
    wire hit0 = cv && ct == tag0;
    wire pending0 = busy0 && (!done[tag0] || trap[tag0]) && !hit0 && !(commit && trap[head] && head==tag0);
    wire [31:0] source0 = busy0 ? (hit0 ? cd : (commit && trap[head] && head==tag0) ? trap_i_value : result[tag0]) : i_rf_rs1_data;

    // integer rs2 uses the same rename and forwarding path
    wire busy1; wire [2:0] tag1;
    reg [31:0] v1[0:7]; reg [4:0] addr1[0:7];
    reg [2:0] q1[0:7]; reg [7:0] wait1;
    wire hit1 = cv && ct == tag1;
    wire pending1 = busy1 && (!done[tag1] || trap[tag1]) && !hit1 && !(commit && trap[head] && head==tag1);
    wire [31:0] source1 = busy1 ? (hit1 ? cd : (commit && trap[head] && head==tag1) ? trap_i_value : result[tag1]) : i_rf_rs2_data;

    // FP source operands have their own RAT, including writable register f0
    wire busy2; wire [2:0] tag2;
    reg [31:0] v2[0:7]; reg [4:0] addr2[0:7];
    reg [2:0] q2[0:7]; reg [7:0] wait2;
    wire hit2 = cv && ct == tag2;
    wire pending2 = busy2 && (!done[tag2] || trap[tag2]) && !hit2 && !(commit && trap[head] && head==tag2);
    wire [31:0] source2 = busy2 ? (hit2 ? cd : (commit && trap[head] && head==tag2) ? trap_f_value : result[tag2]) : i_rf_frs1_data;

    // second FP operand (also used as the data for FP stores)
    wire busy3; wire [2:0] tag3;
    reg [31:0] v3[0:7]; reg [4:0] addr3[0:7];
    reg [2:0] q3[0:7]; reg [7:0] wait3;
    wire hit3 = cv && ct == tag3;
    wire pending3 = busy3 && (!done[tag3] || trap[tag3]) && !hit3 && !(commit && trap[head] && head==tag3);
    wire [31:0] source3 = busy3 ? (hit3 ? cd : (commit && trap[head] && head==tag3) ? trap_f_value : result[tag3]) : i_rf_frs2_data;

    // third FP operand for fused multiply-add instructions
    wire busy4; wire [2:0] tag4;
    reg [31:0] v4[0:7]; reg [4:0] addr4[0:7];
    reg [2:0] q4[0:7]; reg [7:0] wait4;
    wire hit4 = cv && ct == tag4;
    wire pending4 = busy4 && (!done[tag4] || trap[tag4]) && !hit4 && !(commit && trap[head] && head==tag4);
    wire [31:0] source4 = busy4 ? (hit4 ? cd : (commit && trap[head] && head==tag4) ? trap_f_value : result[tag4]) : i_rf_frs3_data;

    // [EBR+BP] Only checkpoint the RAT if the conditional branch has pending operands
    // (if it resolves at issue, no speculative instructions will ever issue behind it)
    wire issue_wait0      = (i_dec_rs1 != 5'd0) && pending0;
    wire issue_wait1      = (i_dec_rs2 != 5'd0) && pending1;
    wire issue_ctrl_ready = issue_ctrl && !issue_wait0 && !issue_wait1;
    wire issue_ctrl_wait  = issue_ctrl && (issue_wait0 || issue_wait1);
    wire ckpt_save = issue && !terminal && i_dec_branch && issue_ctrl_wait;

    // separate integer and FP rename tables, both use the same ROB tags
    rat #(.ZERO_REG(1)) rat_0 (.i_clk(i_clk), .i_rst(i_rst), .i_rs1_addr(i_dec_rs1), .o_rs1_busy(busy0), .o_rs1_tag(tag0), .i_rs2_addr(i_dec_rs2), .o_rs2_busy(busy1), .o_rs2_tag(tag1), .i_rs3_addr(5'd0), .o_rs3_busy(), .o_rs3_tag(), .i_rename_en(issue && wi), .i_rename_rd(i_dec_rd), .i_rename_tag(tail), .i_commit_en(commit && iw[head]), .i_commit_rd(rd[head]), .i_commit_tag(head), .i_flush(1'b0), .i_ckpt_save(ckpt_save), .i_ckpt_restore(mispred), .o_busy());
    rat #(.ZERO_REG(0)) rat_1 (.i_clk(i_clk), .i_rst(i_rst), .i_rs1_addr(i_dec_frs1_addr), .o_rs1_busy(busy2), .o_rs1_tag(tag2), .i_rs2_addr(i_dec_frs2_addr), .o_rs2_busy(busy3), .o_rs2_tag(tag3), .i_rs3_addr(i_dec_frs3_addr), .o_rs3_busy(busy4), .o_rs3_tag(tag4), .i_rename_en(issue && wf), .i_rename_rd(i_dec_rd), .i_rename_tag(tail), .i_commit_en(commit && fw[head]), .i_commit_rd(rd[head]), .i_commit_tag(head), .i_flush(1'b0), .i_ckpt_save(ckpt_save), .i_ckpt_restore(mispred), .o_busy());
    // count occupied reservation station entries, not all live ROB entries
    assign icount = {3'b0,irs[0]} + {3'b0,irs[1]} + {3'b0,irs[2]} + {3'b0,irs[3]} + {3'b0,irs[4]} + {3'b0,irs[5]} + {3'b0,irs[6]} + {3'b0,irs[7]};
    assign fcount = {3'b0,frs[0]} + {3'b0,frs[1]} + {3'b0,frs[2]} + {3'b0,frs[3]} + {3'b0,frs[4]} + {3'b0,frs[5]} + {3'b0,frs[6]} + {3'b0,frs[7]};
    // an entry can execute once all of its operand wait bits are clear
    wire [7:0] ready;
    genvar g; generate for(g=0;g<8;g=g+1) begin: readiness
        assign ready[g] = !(wait0[g] || wait1[g] || wait2[g] || wait3[g] || wait4[g]);
    end endgenerate
    // scan from the ROB head so the oldest ready integer instruction wins
    // 3-bit tag addition wraps around the 8-entry ROB
    wire [2:0] intt0 = head + 3'd0; wire intr0 = irs[intt0] && ready[intt0];
    wire [2:0] intt1 = head + 3'd1; wire intr1 = irs[intt1] && ready[intt1];
    wire [2:0] intt2 = head + 3'd2; wire intr2 = irs[intt2] && ready[intt2];
    wire [2:0] intt3 = head + 3'd3; wire intr3 = irs[intt3] && ready[intt3];
    wire [2:0] intt4 = head + 3'd4; wire intr4 = irs[intt4] && ready[intt4];
    wire [2:0] intt5 = head + 3'd5; wire intr5 = irs[intt5] && ready[intt5];
    wire [2:0] intt6 = head + 3'd6; wire intr6 = irs[intt6] && ready[intt6];
    wire [2:0] intt7 = head + 3'd7; wire intr7 = irs[intt7] && ready[intt7];
    wire intfound = intr0 || intr1 || intr2 || intr3 || intr4 || intr5 || intr6 || intr7;
    wire [2:0] intpick = intr0 ? intt0 : intr1 ? intt1 : intr2 ? intt2 : intr3 ? intt3 : intr4 ? intt4 : intr5 ? intt5 : intr6 ? intt6 : intr7 ? intt7 : 3'd0;
    // oldest ready FP instruction wins, CSR instructions wait for the ROB head
    wire [2:0] fpt0 = head + 3'd0; wire fpr0 = frs[fpt0] && ready[fpt0] && (inst[fpt0][6:0]!=7'h73 || fpt0==head);
    wire [2:0] fpt1 = head + 3'd1; wire fpr1 = frs[fpt1] && ready[fpt1] && (inst[fpt1][6:0]!=7'h73 || fpt1==head);
    wire [2:0] fpt2 = head + 3'd2; wire fpr2 = frs[fpt2] && ready[fpt2] && (inst[fpt2][6:0]!=7'h73 || fpt2==head);
    wire [2:0] fpt3 = head + 3'd3; wire fpr3 = frs[fpt3] && ready[fpt3] && (inst[fpt3][6:0]!=7'h73 || fpt3==head);
    wire [2:0] fpt4 = head + 3'd4; wire fpr4 = frs[fpt4] && ready[fpt4] && (inst[fpt4][6:0]!=7'h73 || fpt4==head);
    wire [2:0] fpt5 = head + 3'd5; wire fpr5 = frs[fpt5] && ready[fpt5] && (inst[fpt5][6:0]!=7'h73 || fpt5==head);
    wire [2:0] fpt6 = head + 3'd6; wire fpr6 = frs[fpt6] && ready[fpt6] && (inst[fpt6][6:0]!=7'h73 || fpt6==head);
    wire [2:0] fpt7 = head + 3'd7; wire fpr7 = frs[fpt7] && ready[fpt7] && (inst[fpt7][6:0]!=7'h73 || fpt7==head);
    wire fpfound = fpr0 || fpr1 || fpr2 || fpr3 || fpr4 || fpr5 || fpr6 || fpr7;
    wire [2:0] fppick = fpr0 ? fpt0 : fpr1 ? fpt1 : fpr2 ? fpt2 : fpr3 ? fpt3 : fpr4 ? fpt4 : fpr5 ? fpt5 : fpr6 ? fpt6 : fpr7 ? fpt7 : 3'd0;
    // select the oldest memory instruction even if its operands are not ready
    // younger memory operations cannot bypass it
    wire [2:0] memt0 = head + 3'd0; wire memr0 = lsu[memt0];
    wire [2:0] memt1 = head + 3'd1; wire memr1 = lsu[memt1];
    wire [2:0] memt2 = head + 3'd2; wire memr2 = lsu[memt2];
    wire [2:0] memt3 = head + 3'd3; wire memr3 = lsu[memt3];
    wire [2:0] memt4 = head + 3'd4; wire memr4 = lsu[memt4];
    wire [2:0] memt5 = head + 3'd5; wire memr5 = lsu[memt5];
    wire [2:0] memt6 = head + 3'd6; wire memr6 = lsu[memt6];
    wire [2:0] memt7 = head + 3'd7; wire memr7 = lsu[memt7];
    wire memfound = memr0 || memr1 || memr2 || memr3 || memr4 || memr5 || memr6 || memr7;
    wire [2:0] mempick = memr0 ? memt0 : memr1 ? memt1 : memr2 ? memt2 : memr3 ? memt3 : memr4 ? memt4 : memr5 ? memt5 : memr6 ? memt6 : memr7 ? memt7 : 3'd0;
    // ia tracks an active ALU operation, iv holds a result waiting for the CDB
    reg ia, iv; reg [2:0] it; reg [31:0] idata;
    wire ig, fg0, fg1, lg;
    wire [2:0] ix = ia ? it : intpick;
    wire [31:0] ar; wire ab, ae, al;

    // [EBR+BP] Block ALU dispatch on a mispredict flush cycle (just like fstart)
    wire istart = intfound && !mispred && !ia && (!iv || ig);
    alu integer_alu(.i_clk(i_clk),.i_rst(i_rst),.i_opsel(opcode[ix]),.i_sub(subop[ix]),.i_unsigned(aluuns[ix]),.i_arith(arith[ix]),.i_mext((ia || istart) && mext[ix]),.i_advance(ia && !ab),.i_op1(op1[ix] ? pc[ix] : v0[ix]),.i_op2(op2[ix] ? imm[ix] : v1[ix]),.o_result(ar),.o_eq(ae),.o_slt(al),.o_busy(ab));
    wire execute = (ia || istart) && !ab;

// [EBR+BP] 1. Issue-time fast path: resolve ready branches/jumps immediately at issue
    wire [31:0] iss_v0          = (i_dec_rs1 != 5'd0) ? source0 : 32'd0;
    wire [31:0] iss_v1          = (i_dec_rs2 != 5'd0) ? source1 : 32'd0;
    wire        iss_signed_lt   = (iss_v0[31] != iss_v1[31]) ? iss_v0[31] : (iss_v0 < iss_v1);
    wire        iss_unsigned_lt = iss_v0 < iss_v1;
    wire        iss_branch_cmp  = i_dec_branch_equal ? (iss_v0 == iss_v1) :
                                  (i_dec_branch_unsigned ? iss_unsigned_lt : iss_signed_lt);
    wire        iss_take        = i_dec_jump || (i_dec_branch && (iss_branch_cmp != i_dec_branch_invert));
    wire [31:0] iss_target      = i_dec_pc_sel ? ((iss_v0 + i_dec_imm) & 32'hfffffffe) : (i_id_pc + i_dec_imm);
    wire        iss_badtarget   = iss_take && (iss_target[1:0] != 2'b00);
    wire        iss_fire        = issue && issue_ctrl_ready;
    wire [31:0] iss_act_npc     = iss_take ? iss_target : (i_id_pc + 32'd4);
    wire [31:0] iss_prd_npc     = (i_id_pred_taken && i_dec_branch) ? i_id_pred_target : (i_id_pc + 32'd4);
    wire        iss_mispred     = iss_fire && !iss_badtarget && (iss_act_npc != iss_prd_npc);

    // [EBR+BP] 2. Dedicated branch resolver: wakes up on the SAME cycle CDB broadcasts operands
    wire        br_w0_cdb       = wait0[br_tag] && cv && (q0[br_tag] == ct);
    wire        br_w0_trap      = wait0[br_tag] && commit && trap[head] && (q0[br_tag] == head);
    wire        br_w1_cdb       = wait1[br_tag] && cv && (q1[br_tag] == ct);
    wire        br_w1_trap      = wait1[br_tag] && commit && trap[head] && (q1[br_tag] == head);
    wire        br_rdy0         = !wait0[br_tag] || br_w0_cdb || br_w0_trap;
    wire        br_rdy1         = !wait1[br_tag] || br_w1_cdb || br_w1_trap;
    wire        br_fire         = br_valid && br_rdy0 && br_rdy1;

    wire [31:0] br_v0           = br_w0_cdb ? cd : br_w0_trap ? trap_i_value : v0[br_tag];
    wire [31:0] br_v1           = br_w1_cdb ? cd : br_w1_trap ? trap_i_value : v1[br_tag];
    wire        br_signed_lt    = (br_v0[31] != br_v1[31]) ? br_v0[31] : (br_v0 < br_v1);
    wire        br_unsigned_lt  = br_v0 < br_v1;
    wire        br_cmp          = eqmode[br_tag] ? (br_v0 == br_v1) :
                                  (bunsigned[br_tag] ? br_unsigned_lt : br_signed_lt);
    wire        br_take         = jump[br_tag] || (branch[br_tag] && (br_cmp != invert[br_tag]));
    wire [31:0] br_target       = pcsel[br_tag] ? ((br_v0 + imm[br_tag]) & 32'hfffffffe) : (pc[br_tag] + imm[br_tag]);
    wire        br_badtarget    = br_take && (br_target[1:0] != 2'b00);
    wire [31:0] br_act_npc      = br_take ? br_target : (pc[br_tag] + 32'd4);
    wire [31:0] br_prd_npc      = ppred[br_tag] ? ptgt[br_tag] : (pc[br_tag] + 32'd4);

    // [EBR+BP] Backend flush (`mispred`) only needed for the dedicated slot (issue-time has no younger ROB entries)
    // Frontend redirect (`o_taken`) fires for BOTH dedicated-slot and issue-time mispredicts
    assign mispred   = br_fire && !br_badtarget && (br_act_npc != br_prd_npc);
    assign o_taken   = mispred || iss_mispred;
    assign o_pc_jump = mispred ? br_act_npc : iss_act_npc;

    // [EBR+BP] Train dynamic branch predictor from BOTH resolution paths
    // only resolved conditional branches with valid targets train the predictor
    wire br_bp_upd  = br_fire  && branch[br_tag] && !br_badtarget;
    wire iss_bp_upd = iss_fire && i_dec_branch   && !iss_badtarget;
    assign o_bp_upd_valid  = br_bp_upd || iss_bp_upd;
    assign o_bp_upd_pc     = br_bp_upd ? pc[br_tag] : i_id_pc;
    assign o_bp_upd_taken  = br_bp_upd ? br_take    : iss_take;
    assign o_bp_upd_target = br_bp_upd ? br_target  : iss_target;

    // [EBR+BP] Age of the resolving branch in the dedicated slot; also detect younger ALU ops to squash
    // use distance from head to identify younger operations across tag wraparound
    wire [2:0] bage     = br_tag - head;
    wire [2:0] it_age   = it - head;
    wire       kill_int = mispred && (ia || iv) && (it_age > bage);

    // each FP lane has its own active bit, result valid bit and producer tag
    reg [1:0] fa, fv;
    reg [2:0] ft[0:1]; reg [31:0] fd[0:1];
    wire [1:0] fgrant = {fg1,fg0};
    wire [1:0] fstart;
    // [BP] no FP dispatch in the flush cycle (the pick could be a squashed entry)
    // lane 0 gets first choice, lane 1 can take the pick if lane 0 cannot start
    assign fstart[0] = fpfound && !mispred && !fa[0] && (!fv[0] || fg0);
    assign fstart[1] = fpfound && !mispred && !fstart[0] && !fa[1] && (!fv[1] || fg1);
    wire [1:0] fb, ftrap;
    wire [31:0] fresult[0:1], firesult[0:1]; wire [4:0] fflags[0:1];
    // instantiate two FP units with the shared architectural CSR inputs
    genvar lane; generate for(lane=0;lane<2;lane=lane+1) begin: fp_lane
        fpu unit(.i_clk(i_clk),.i_rst(i_rst),.i_inst(inst[ft[lane]]),.i_valid(fa[lane]),.i_advance(fa[lane] && !fb[lane]),.i_frs1(v2[ft[lane]]),.i_frs2(v3[ft[lane]]),.i_frs3(v4[ft[lane]]),.i_xrs1(v0[ft[lane]]),.o_fp_result(fresult[lane]),.o_int_result(firesult[lane]),.o_fflags(fflags[lane]),.o_busy(fb[lane]),.i_shared_frm(shared_fcsr[7:5]),.i_shared_flags(shared_fcsr[4:0]),.o_rm_trap(ftrap[lane]));
    end endgenerate
    // LSU address generation, alignment check and byte lane selection
    wire [2:0] mx = mempick;
    wire [31:0] ma = v0[mx]+imm[mx];
    wire misalign = (wordop[mx] && ma[1:0]!=0) || (halfop[mx] && ma[0]);
    wire [3:0] mask = wordop[mx] ? 4'b1111 : halfop[mx] ? (ma[1] ? 4'b1100 : 4'b0011) : ma[1:0]==0 ? 4'b0001 : ma[1:0]==1 ? 4'b0010 : ma[1:0]==2 ? 4'b0100 : 4'b1000;
    // select integer or FP store data and align it to the addressed byte lanes
    wire [31:0] sd = inst[mx][6:0]==7'b0100111 ? v3[mx] : v1[mx];
    wire [31:0] aligned = ma[1:0]==0 ? sd : ma[1:0]==1 ? sd<<8 : ma[1:0]==2 ? sd<<16 : sd<<24;
    // shift the selected load bytes down before sign or zero extension
    wire [31:0] shifted = ma[1:0]==0 ? i_dcache_rdata : ma[1:0]==1 ? i_dcache_rdata>>8 : ma[1:0]==2 ? i_dcache_rdata>>16 : i_dcache_rdata>>24;
    wire [31:0] lddata = byteop[mx] ? {{24{!uns[mx] && shifted[7]}},shifted[7:0]} : halfop[mx] ? {{16{!uns[mx] && shifted[15]}},shifted[15:0]} : shifted;
    // buffer a completed load if another producer wins the CDB
    reg lv; reg [2:0] lt; reg [31:0] ld;
    wire memready = memfound && ready[mx] && !misalign;
    assign o_dcache_ren = memready && load[mx] && !lv && !i_rst;
    // stores may update the cache only when they reach the ROB head
    assign o_dcache_wen = memready && store[mx] && mx==head && done[head] && !i_rst;
    assign o_dcache_addr = ma;
    assign o_dcache_mask = mask;
    assign o_dcache_wdata = aligned;
    // a load result is accepted only when the cache reports ready
    wire ldreq = o_dcache_ren && i_dcache_ready;

    // [BP] load results that belong to squashed (younger) loads
    wire [2:0] lt_age = lt - head;
    wire [2:0] mx_age = mx - head;
    wire kill_lv    = mispred && lv    && (lt_age > bage);
    wire kill_ldreq = mispred && ldreq && (mx_age > bage);

    // arbitrate between the integer unit, both FP lanes and the load result
    cdb_arb arb(.i_rob_head(head),.i_int_v(iv),.i_int_tag(it),.i_int_value(idata),.i_fp0_v(fv[0]),.i_fp0_tag(ft[0]),.i_fp0_value(fd[0]),.i_fp1_v(fv[1]),.i_fp1_tag(ft[1]),.i_fp1_value(fd[1]),.i_ld_v(lv || ldreq),.i_ld_tag(lv ? lt : mx),.i_ld_value(lv ? ld : lddata),.o_int_grant(ig),.o_fp0_grant(fg0),.o_fp1_grant(fg1),.o_ld_grant(lg),.o_cdb_valid(cv),.o_cdb_tag(ct),.o_cdb_value(cd));
    // retire only the completed head entry, stores also wait for cache acceptance
    assign commit = !i_rst && live[head] && done[head] && (!store[head] || trap[head] || (o_dcache_wen && i_dcache_ready));
    // completion reports the CDB broadcast, separate from in-order retirement
    assign o_complete_valid = cv && !i_rst;
    assign o_complete_tag = ct;
    assign o_complete_rd = iw[ct] || fw[ct] ? rd[ct] : 0;
    assign o_complete_value = cd;
    assign o_complete_pc = pc[ct];
    // architectural register writes happen at retirement, never on a trap
    assign o_rf_wen = commit && iw[head] && !trap[head];
    assign o_frd_wen = commit && fw[head] && !trap[head];
    assign o_rf_waddr = rd[head]; assign o_frd_waddr = rd[head];
    assign o_rf_wdata = result[head]; assign o_frd_wdata = result[head];
    assign o_retire_valid = commit;
    assign o_retire_inst = inst[head]; assign o_retire_pc = pc[head]; assign o_retire_next_pc = npc[head];
    assign o_retire_trap = trap[head]; assign o_retire_halt = halt[head];
    assign o_retire_rd_waddr = o_rf_wen ? rd[head] : 0;
    assign o_retire_rd_wdata = o_rf_wen ? result[head] : 0;
    assign o_retire_frd_wen = o_frd_wen; assign o_retire_frd_waddr = o_frd_wen ? rd[head] : 0;
    assign o_retire_frd_wdata = o_frd_wen ? result[head] : 0;
    // report the flags after applying the retiring instruction
    // this includes CSR writes and newly accrued FP exceptions
    assign o_retire_fflags = next_fcsr[4:0];
    // reconstruct the retiring memory operation from its saved operands
    wire [31:0] ra = v0[head]+imm[head];
    wire [31:0] rsd = inst[head][6:0]==7'b0100111 ? v3[head] : v1[head];
    assign o_retire_dmem_ren = load[head] && !trap[head];
    assign o_retire_dmem_wen = store[head] && !trap[head];
    wire rm = o_retire_dmem_ren || o_retire_dmem_wen;
    assign o_retire_dmem_addr = rm ? ra : 0;
    assign o_retire_dmem_mask = !rm ? 0 : wordop[head] ? 15 : halfop[head] ? (ra[1] ? 12 : 3) : ra[1:0]==0 ? 1 : ra[1:0]==1 ? 2 : ra[1:0]==2 ? 4 : 8;
    assign o_retire_dmem_rdata = o_retire_dmem_ren ? memraw[head] : 0;
    assign o_retire_dmem_wdata = !o_retire_dmem_wen ? 0 : ra[1:0]==0 ? rsd : ra[1:0]==1 ? rsd<<8 : ra[1:0]==2 ? rsd<<16 : rsd<<24;

    // report the source addresses and values saved in the retiring ROB entry
    assign o_retire_rs1_raddr = addr0[head]; assign o_retire_rs1_rdata = v0[head];
    assign o_retire_rs2_raddr = addr1[head]; assign o_retire_rs2_rdata = v1[head];
    assign o_retire_frs1_raddr = addr2[head]; assign o_retire_frs1_rdata = v2[head];
    assign o_retire_frs2_raddr = addr3[head]; assign o_retire_frs2_rdata = v3[head];
    assign o_retire_frs3_raddr = addr4[head]; assign o_retire_frs3_rdata = v4[head];

    always @(posedge i_clk) begin
        if(i_rst) begin 
            head<=0; tail<=0; count<=0; ctrl<=0; cbr_inflight<=0; ia<=0; iv<=0; lv<=0; 
            // [EBR+BP] Reset dedicated branch slot
            br_valid<=1'b0; br_tag<=3'd0;
        end
        else begin
            case ({issue,commit}) 2'b10: count<=count+1'b1; 2'b01: count<=count-1'b1; default: count<=count; endcase
            if(commit) head<=head+1'b1;
            if(issue) begin
                tail<=tail+1'b1;
                // [EBR+BP] Only set ctrl/cbr_inflight & load dedicated slot if operands are pending
                if(issue_ctrl_wait) begin
                    br_valid<=1'b1;
                    br_tag<=tail;
                    if(i_dec_jump) ctrl<=1'b1;
                    if(i_dec_branch) cbr_inflight<=1'b1;
                end
            end
            // [EBR+BP] Clear dedicated slot and in-flight flags as soon as branch/jump resolves
            if(br_fire) begin
                br_valid<=1'b0;
                if(jump[br_tag]) ctrl<=1'b0;
                if(branch[br_tag]) cbr_inflight<=1'b0;
            end
            if(ig) iv<=0;
            if(istart) begin it<=ix; ia<=ab; end
            if(execute) begin
                ia<=0;
                // [EBR+BP] Branches/jumps no longer execute on the ALU
                iv<=1'b1;
                it<=ix;
                idata<=branch[ix] ? 0 : jump[ix] ? pc[ix]+4 :
                    lui[ix] ? imm[ix] : ar;
            end
            if(lg) lv<=0;
            if(ldreq && !lg) begin lv<=1; lt<=mx; ld<=lddata; end

            // [EBR+BP] Mispredict flush (kept last so it wins): keep ROB up to br_tag
            if(mispred) begin
                tail  <= br_tag + 3'd1;
                count <= {1'b0,bage} + 4'd1 - {3'b0,commit};
            end
            // [EBR+BP] Squash any younger speculative ALU or load op on mispredict
            if(kill_int) begin ia<=1'b0; iv<=1'b0; end
            if(kill_lv || kill_ldreq) lv<=0;
        end
    end
    // independent FP lane state, hold completed results until granted the CDB
    genvar f; generate for(f=0;f<2;f=f+1) begin: fp_state
        wire [2:0] fage = ft[f] - head;
        wire kill_f = mispred && (fa[f] || fv[f]) && (fage > bage);
        always @(posedge i_clk) begin
            if(i_rst) begin ft[f]<=0; fd[f]<=0; fa[f]<=0; fv[f]<=0; end
            else begin
                if(fgrant[f]) fv[f]<=0;
                if(fstart[f]) begin fa[f]<=1; ft[f]<=fppick; end
                if(fa[f] && !fb[f]) begin fa[f]<=0; fv[f]<=!ftrap[f]; fd[f]<=fw[ft[f]] ? fresult[f] : firesult[f]; end
                // [BP] drop a squashed FP op (running or waiting for the CDB)
                if(kill_f) begin fa[f]<=0; fv[f]<=0; end
            end
        end
    end endgenerate
    // one sequential block per ROB entry, generated at elaboration
    genvar k; generate for(k=0;k<8;k=k+1) begin: entry
        localparam [2:0] KK = k;
        // compare this entry against the resolving branch in ROB age order
        wire [2:0] kage = KK - head;
        always @(posedge i_clk) begin
            if(i_rst) begin live[k]<=0; done[k]<=0; irs[k]<=0; frs[k]<=0; lsu[k]<=0; trap[k]<=0; halt[k]<=0;

                wait0[k]<=0;
                wait1[k]<=0;
                wait2[k]<=0;
                wait3[k]<=0;
                wait4[k]<=0;
            end else begin
                if(commit && head==k) begin live[k]<=0; lsu[k]<=0; end
                if(istart && ix==k) irs[k]<=0;
                if((|fstart) && fppick==k) frs[k]<=0;
                
                // [EBR+BP] Dedicated branch slot writes npc, link result, done, and trap
                if(br_fire && br_tag==k) begin
                    done[k]<=1'b1;
                    npc[k]<=(br_take && !br_badtarget) ? br_target : (pc[k]+32'd4);
                    result[k]<=(jump[k] && !br_badtarget) ? (pc[k]+32'd4) : 32'd0;
                    if(br_badtarget) trap[k]<=1'b1;
                end

                // capture the winning result and mark its ROB entry complete
                if(cv && ct==k) begin done[k]<=1; result[k]<=cd; if(lg) lsu[k]<=0; end
                if(ldreq && mx==k) memraw[k]<=i_dcache_rdata;
                if(memfound && mx==k && ready[k]) begin
                    if(misalign) begin trap[k]<=1; done[k]<=1; lsu[k]<=0; end
                    else if(store[k]) done[k]<=1;
                end
                if(fa[0] && !fb[0] && ft[0]==k) begin flags[k]<=fflags[0]; if(ftrap[0]) begin trap[k]<=1; done[k]<=1; end end
                if(fa[1] && !fb[1] && ft[1]==k) begin flags[k]<=fflags[1]; if(ftrap[1]) begin trap[k]<=1; done[k]<=1; end end

                // wake waiting operands on a matching CDB tag
                // trapped producers instead release operands with the committed register value
                if(live[k] && wait0[k] && cv && q0[k]==ct) begin wait0[k]<=0; v0[k]<=cd; end
                if(live[k] && wait0[k] && commit && trap[head] && q0[k]==head) begin wait0[k]<=0; v0[k]<=trap_i_value; end
                if(live[k] && wait1[k] && cv && q1[k]==ct) begin wait1[k]<=0; v1[k]<=cd; end
                if(live[k] && wait1[k] && commit && trap[head] && q1[k]==head) begin wait1[k]<=0; v1[k]<=trap_i_value; end
                if(live[k] && wait2[k] && cv && q2[k]==ct) begin wait2[k]<=0; v2[k]<=cd; end
                if(live[k] && wait2[k] && commit && trap[head] && q2[k]==head) begin wait2[k]<=0; v2[k]<=trap_f_value; end
                if(live[k] && wait3[k] && cv && q3[k]==ct) begin wait3[k]<=0; v3[k]<=cd; end
                if(live[k] && wait3[k] && commit && trap[head] && q3[k]==head) begin wait3[k]<=0; v3[k]<=trap_f_value; end
                if(live[k] && wait4[k] && cv && q4[k]==ct) begin wait4[k]<=0; v4[k]<=cd; end
                if(live[k] && wait4[k] && commit && trap[head] && q4[k]==head) begin wait4[k]<=0; v4[k]<=trap_f_value; end
                // allocate the tail entry and save decoded controls, operands and tags
                if(issue && tail==k) begin
                    
                    // [EBR+BP] Ready branches/jumps complete immediately at issue; never enter `irs`
                    live[k]<=1'b1;
                    done[k]<=terminal || issue_ctrl_ready;
                    trap[k]<=!i_dec_legal || (issue_ctrl_ready && iss_badtarget);
                    halt[k]<=i_dec_halt;
                    irs[k]<=!terminal && !ismem && !isfp && !issue_ctrl;
                    frs[k]<=!terminal && isfp;
                    lsu[k]<=!terminal && ismem;
                    inst[k]<=i_id_inst; pc[k]<=i_id_pc;
                    npc[k]<=(issue_ctrl_ready && iss_take && !iss_badtarget) ? iss_target : (i_id_pc+32'd4);
                    imm[k]<=i_dec_imm; rd[k]<=i_dec_rd; flags[k]<=0;
                    result[k]<=(issue_ctrl_ready && i_dec_jump && !iss_badtarget) ? (i_id_pc+32'd4) : 32'd0;
                    memraw[k]<=0;
                    
                    iw[k]<=wi; fw[k]<=wf; lui[k]<=i_dec_rd_sel[1]; opcode[k]<=i_dec_alu_opsel;

                    load[k]<=i_dec_dmem_ren;
                    store[k]<=i_dec_dmem_wen;
                    byteop[k]<=i_dec_dmem_memb;
                    halfop[k]<=i_dec_dmem_memh;
                    wordop[k]<=i_dec_dmem_memw;
                    uns[k]<=i_dec_dmem_memu;
                    branch[k]<=i_dec_branch;
                    jump[k]<=i_dec_jump;
                    eqmode[k]<=i_dec_branch_equal;
                    bunsigned[k]<=i_dec_branch_unsigned;
                    invert[k]<=i_dec_branch_invert;
                    pcsel[k]<=i_dec_pc_sel;
                    op1[k]<=i_dec_op1_sel;
                    op2[k]<=i_dec_op2_sel;
                    subop[k]<=i_dec_alu_sub;
                    aluuns[k]<=i_dec_alu_unsigned;
                    arith[k]<=i_dec_alu_arith;
                    mext[k]<=i_dec_mext;
                    // [BP] only conditional branches are ever predicted taken
                    ppred[k]<=i_id_pred_taken && i_dec_branch;
                    ptgt[k]<=i_id_pred_target;
                    // latch available values now, otherwise wait for the saved producer tag
                    addr0[k]<=(i_dec_rs1!=0) ? i_dec_rs1 : 0; v0[k]<=(i_dec_rs1!=0) ? source0 : 0; q0[k]<=tag0; wait0[k]<=(i_dec_rs1!=0) && pending0;
                    addr1[k]<=(i_dec_rs2!=0) ? i_dec_rs2 : 0; v1[k]<=(i_dec_rs2!=0) ? source1 : 0; q1[k]<=tag1; wait1[k]<=(i_dec_rs2!=0) && pending1;
                    addr2[k]<=(i_dec_frs1_en) ? i_dec_frs1_addr : 0; v2[k]<=(i_dec_frs1_en) ? source2 : 0; q2[k]<=tag2; wait2[k]<=(i_dec_frs1_en) && pending2;
                    addr3[k]<=(i_dec_frs2_en) ? i_dec_frs2_addr : 0; v3[k]<=(i_dec_frs2_en) ? source3 : 0; q3[k]<=tag3; wait3[k]<=(i_dec_frs2_en) && pending3;
                    addr4[k]<=(i_dec_frs3_en) ? i_dec_frs3_addr : 0; v4[k]<=(i_dec_frs3_en) ? source4 : 0; q4[k]<=tag4; wait4[k]<=(i_dec_frs3_en) && pending4;
                end

                // [BP] mispredict flush: squash every entry younger than the branch
                // (kept last so it wins over the CDB / dispatch updates above)
                if(mispred && live[k] && (kage > bage)) begin
                    live[k]<=0; done[k]<=0; irs[k]<=0; frs[k]<=0; lsu[k]<=0;
                    trap[k]<=0; halt[k]<=0;
                    wait0[k]<=0; wait1[k]<=0; wait2[k]<=0; wait3[k]<=0; wait4[k]<=0;
                end
            end
        end
    end endgenerate
endmodule
`default_nettype wire
