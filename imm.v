// The immediate generator is responsible for decoding the 32-bit
// sign-extended immediate from the incoming instruction word. It is a purely
// combinational block that is expected to be embedded in the instruction
// decoder.
module imm (
    // Input instruction word. This is used to extract the relevant immediate
    // bits and assemble them into the final immediate.
    input  wire [31:0] i_inst,
    // Instruction format, determined by the instruction decoder based on the
    // opcode. This is one-hot encoded according to the following format:
    // [0] R-type
    // [1] I-type
    // [2] S-type
    // [3] B-type
    // [4] U-type
    // [5] J-type
    // Because the R-type format does not have an immediate, the output
    // immediate can be treated as a don't-care under this case.
    input  wire [ 5:0] i_format,
    // Output 32-bit immediate, sign-extended from the immediate bitstring.
    output wire [31:0] o_immediate
);
    // Your implementation goes under here
    // ------------------------------------

    reg [31:0] immediate; // placeholder for what type it is

    // phase 4: one wire per format
    wire [31:0] imm_i;
    wire [31:0] imm_s;
    wire [31:0] imm_b;
    wire [31:0] imm_u;
    wire [31:0] imm_j;

   // phase 4: assign immediates by type
   assign imm_i = {{20{i_inst[31]}}, i_inst[31:20]}; // I type
   assign imm_s = {{20{i_inst[31]}}, i_inst[31:25], i_inst[11:7]}; // S type
   assign imm_b = {{19{i_inst[31]}}, i_inst[31], i_inst[7], i_inst[30:25], i_inst[11:8], 1'b0}; // B type
   assign imm_u = {i_inst[31:12], 12'b0}; // U type
   assign imm_b = {{11{i_inst[31]}}, i_inst[31], i_inst[19:12], i_inst[20], i_inst[30:21], 1'b0}; // J type

   // phase 4: select by corresponding bit fields per type
    assign o_immediate = 
        (i_format == 6'b000010) ? imm_i :
        (i_format == 6'b000100) ? imm_s :
        (i_format == 6'b001000) ? imm_b :
        (i_format == 6'b010000) ? imm_u :
        (i_format == 6'b100000) ? imm_j : 32'b0;
        
endmodule //imm
