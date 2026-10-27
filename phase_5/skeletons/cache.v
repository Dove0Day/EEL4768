`default_nettype none

// A set associative cache. `hart` instantiates two of them, one as the
// instruction cache and one as the data cache, and passes the same five
// parameters to both. The replacement, write, and prefetch rules are in
// `documentation/phase_5.pdf`.
module cache #(
    // Replacement policy: 0 = LRU, 1 = PLRU.
    parameter EVICT_POLICY = 0,
    // Lines per set: 1 = direct mapped, the number of lines = fully
    // associative.
    parameter NUM_WAYS     = 1,
    // Data capacity in KB. Tags, valid bits and dirty bits are not counted.
    parameter CACHE_SIZE   = 16,
    // Bytes per line.
    parameter BLOCK_SIZE   = 128,
    // Next-line prefetch on a load miss: 1 = on, 0 = off.
    parameter PREFETCH_EN  = 0
) (
    // Global clock.
    input  wire                    i_clk,
    // Synchronous active-high reset.
    input  wire                    i_rst,
    // CPU side: the phase 4 data memory port, plus `o_ready` to stall the
    // pipeline while the cache waits on main memory. How the cache tells the
    // pipeline to stall is up to you, so you can change these ports.
    input  wire                    i_ren,
    input  wire                    i_wen,
    input  wire [31:0]             i_addr,
    input  wire [ 3:0]             i_mask,
    input  wire [31:0]             i_wdata,
    output wire                    o_ready,
    output wire [31:0]             o_rdata,
    // Memory side: one whole line (BLOCK_SIZE bytes) per transfer.
    //
    // Line read request, high for one cycle per request.
    output wire                    o_mem_rd,
    // Line-aligned address of the line to read.
    output wire [31:0]             o_mem_rd_addr,
    // High for one cycle when a requested line arrives. Memory answers
    // requests in order, after a delay set by the testbench: wait for this
    // signal instead of counting cycles.
    input  wire                    i_mem_valid,
    // The whole line, valid while `i_mem_valid` is high.
    input  wire [BLOCK_SIZE*8-1:0] i_mem_rd_data,
    // Line write, high for one cycle per write. Memory applies it on that
    // clock edge.
    output wire                    o_mem_wr,
    // Line-aligned address of the write.
    output wire [31:0]             o_mem_wr_addr,
    // Write data, in place within the line.
    output wire [BLOCK_SIZE*8-1:0] o_mem_wr_data,
    // One bit per byte: all ones for a dirty write-back, only the stored
    // bytes for a write-through.
    output wire [BLOCK_SIZE-1:0]   o_mem_wr_be
);

// Write your code here.
// divide each address into block offset, set index, and tag
// number of low address bits to select byte within block
localparam BLOCK_OFFSET_BITS = $clog2(BLOCK_SIZE);
// total cache lines for all sets
localparam NUM_BLOCKS = (CACHE_SIZE * 1024) / BLOCK_SIZE;
// number of independent sets incache
localparam NUM_SETS = NUM_BLOCKS / NUM_WAYS;
// number of address bits used to select set
localparam INDEX_BITS = $clog2(NUM_SETS);
// remaining upper address bits identify memory block
localparam TAG_BITS = 32 - INDEX_BITS - BLOCK_OFFSET_BITS;
// number of data bits stored in cache line
localparam LINE_BITS = BLOCK_SIZE * 8;

// cache memory storage
// one tag and one valid bit, every way in every set
reg [TAG_BITS-1:0] tags [0:NUM_SETS-1][0:NUM_WAYS-1];
reg valid [0:NUM_SETS-1][0:NUM_WAYS-1];

// flags cached line as modified by store
reg dirty [0:NUM_SETS-1][0:NUM_WAYS-1];

// each line stores BLOCK_SIZE bytes
reg [LINE_BITS-1:0] data_array [0:NUM_SETS-1][0:NUM_WAYS-1];

// decode requested address
wire [TAG_BITS-1:0] request_tag;
wire [31:0] request_set;
wire [31:0] block_addr;

// select address fields
generate
    if (INDEX_BITS == 0) begin : gen_fully_associative // fully associative
        assign request_tag = i_addr[31:BLOCK_OFFSET_BITS];
        assign request_set = 32'd0;
    end else begin : gen_indexed // indexed
        assign request_tag = i_addr[31:BLOCK_OFFSET_BITS+INDEX_BITS];
        assign request_set = i_addr[BLOCK_OFFSET_BITS +: INDEX_BITS];
    end
endgenerate

// clear offset bits for line-aligned address
assign block_addr = {i_addr[31:BLOCK_OFFSET_BITS],{BLOCK_OFFSET_BITS{1'b0}}};

// state registers
// controller only advance on the rising clockedge
localparam STATE_IDLE = 3'd0;
localparam STATE_LOOKUP = 3'd1;
localparam STATE_WRITEBACK = 3'd2;
localparam STATE_MEM_READ = 3'd3;
localparam STATE_REFILL = 3'd4;
localparam STATE_WRITE_THRU = 3'd5;
reg [2:0] state;
reg [2:0] next_state;

// save CPU request
reg [31:0] saved_addr;
reg [31:0] saved_wdata;
reg [3:0] saved_mask;
reg saved_ren;
reg saved_wen;

// remember set and way serviced
reg [31:0] saved_set;
reg [TAG_BITS-1:0] saved_tag;
reg [31:0] victim_way;

// detect hits
wire [NUM_WAYS-1:0] way_hit;
wire [NUM_WAYS-1:0] way_invalid; // validate across ways

//choose lower number matchign way
wire [NUM_WAYS:0] hit_seen;
wire [NUM_WAYS:0] invalid_seen;
wire [NUM_WAYS-1:0] first_hit;
wire [NUM_WAYS-1:0] first_invalid;
assign hit_seen[0] = 1'b0;
assign invalid_seen[0] = 1'b0;

// gen loop compare circuit per way
genvar way;
generate
    for (way = 0; way < NUM_WAYS; way = way + 1) begin : gen_way_lookup
        // check if way contains requested block
        assign way_hit[way] = valid[request_set][way] && (tags[request_set][way] == request_tag);
        // invalid line available for allocation
        assign way_invalid[way] = !valid[request_set][way];
        // select hit if no lower-numbered way hit
        assign first_hit[way] = way_hit[way] && !hit_seen[way];
        assign hit_seen[way+1] = hit_seen[way] || way_hit[way];
        // select invalid way only if no earlier way invalid
        assign first_invalid[way] = way_invalid[way] && !invalid_seen[way];
        assign invalid_seen[way+1] = invalid_seen[way] || way_invalid[way];
    end
endgenerate
// reductions across way vectors
wire cache_hit;
wire invalid_way_available;
assign cache_hit = |way_hit;
assign invalid_way_available = |way_invalid;

// convert hit into way number
// one-hot hit and invalids
wire [31:0] hit_way;
wire [31:0] invalid_way;

// one-hot way selection for index bits
localparam WAY_BITS = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS);
wire [WAY_BITS-1:0] hit_way_index;
wire [WAY_BITS-1:0] invalid_way_index;
genvar way_bit;
generate
    for (way_bit = 0; way_bit < WAY_BITS; way_bit = way_bit + 1) begin : gen_way_index // index
        wire [NUM_WAYS-1:0] hit_terms;
        wire [NUM_WAYS-1:0] invalid_terms;
        genvar w;
        for (w = 0; w < NUM_WAYS; w = w + 1) begin : gen_index_terms // index terms
            localparam WAY_NUMBER = w;
            localparam BIT_VALUE = (WAY_NUMBER / (2 ** way_bit)) % 2;
            assign hit_terms[w] = first_hit[w] & BIT_VALUE;
            assign invalid_terms[w] = first_invalid[w] & BIT_VALUE;
        end
        assign hit_way_index[way_bit] = |hit_terms;
        assign invalid_way_index[way_bit] = |invalid_terms;
    end
endgenerate

 // LRU and PLRU implementation
 // lower age means more recently used
 localparam LRU_AGE_BITS = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS);

 // one direction bit per internal node of the replacement tree
 localparam PLRU_NODES = NUM_WAYS - 1;

 reg [LRU_AGE_BITS-1:0] lru_age [0:NUM_SETS-1][0:NUM_WAYS-1];

 reg plru_bits [0:NUM_SETS-1][0:((PLRU_NODES > 0) ? PLRU_NODES-1 : 0)];

 // victim/replacement selection
 // invalid lines take priority over the replacement policy
 wire [WAY_BITS-1:0] victim_way_index;
 wire [WAY_BITS-1:0] policy_victim_way;
 wire [WAY_BITS-1:0] lru_victim_index;
 wire victim_is_invalid;

 // choose the lowest-numbered invalid way when available
 assign victim_way_index = invalid_way_available
                         ? invalid_way_index
                         : policy_victim_way;

 assign victim_is_invalid = invalid_way_available;

 // find the least recently used way
 wire [NUM_WAYS-1:0] lru_victim;

 genvar candidate_way;
 generate
     for (candidate_way = 0;
          candidate_way < NUM_WAYS;
          candidate_way = candidate_way + 1) begin : gen_lru_victim

         wire [NUM_WAYS-1:0] older_way;

         genvar compare_way;
         for (compare_way = 0;
              compare_way < NUM_WAYS;
              compare_way = compare_way + 1) begin : gen_lru_compare

             if (compare_way == candidate_way) begin : gen_same_way
                 assign older_way[compare_way] = 1'b0;
             end else begin : gen_other_way
                 // higher age means the line was used less recently
                 // equal ages favor the lower-numbered way
                 assign older_way[compare_way] =
                     valid[request_set][compare_way] &&
                     ((lru_age[request_set][compare_way] >
                       lru_age[request_set][candidate_way]) ||
                      ((lru_age[request_set][compare_way] ==
                        lru_age[request_set][candidate_way]) &&
                       (compare_way < candidate_way)));
             end
         end

         // select the oldest valid way
         assign lru_victim[candidate_way] =
             valid[request_set][candidate_way] &&
             !(|older_way);
     end
 endgenerate

 // encode the one-hot LRU victim as a binary way index
 genvar victim_bit;
 generate
     for (victim_bit = 0;
          victim_bit < WAY_BITS;
          victim_bit = victim_bit + 1) begin : gen_lru_encode

         wire [NUM_WAYS-1:0] victim_terms;

         genvar victim_number;
         for (victim_number = 0;
              victim_number < NUM_WAYS;
              victim_number = victim_number + 1) begin : gen_lru_terms

             localparam VICTIM_BIT_VALUE =
                 (victim_number / (2 ** victim_bit)) % 2;

             assign victim_terms[victim_number] =
                 lru_victim[victim_number] & VICTIM_BIT_VALUE;
         end

         assign lru_victim_index[victim_bit] = |victim_terms;
     end
 endgenerate

 // select the configured replacement policy
 generate
     if (EVICT_POLICY == 0) begin : gen_lru_policy
         assign policy_victim_way = lru_victim_index;
     end else begin : gen_plru_policy
         // temporary placeholder; PLRU is not implemented yet
         assign policy_victim_way = {WAY_BITS{1'b0}};
     end
 endgenerate

// victim/replacement selection
// invalid lines > replacement policy
wire [WAY_BITS-1:0] victim_way_index;
wire victim_is_invalid;
wire [WAY_BITS-1:0] policy_victim_way; // victim when all ways in set valid

// prefer lowest invalid way
assign victim_way_index = invalid_way_available ? invalid_way_index : policy_victim_way;
assign victim_is_invalid = invalid_way_available;

// request and memory control
reg mem_rd_reg;
reg mem_wr_reg;
reg [31:0] mem_rd_addr_reg;
reg [31:0] mem_wr_addr_reg;
reg [LINE_BITS-1:0] mem_wr_data_reg;
reg [BLOCK_SIZE-1:0] mem_wr_be_reg;
reg [31:0] rdata_reg;
reg ready_reg;

assign o_mem_rd = mem_rd_reg;
assign o_mem_rd_addr = mem_rd_addr_reg;
assign o_mem_wr = mem_wr_reg;
assign o_mem_wr_addr = mem_wr_addr_reg;
assign o_mem_wr_data = mem_wr_data_reg;
assign o_mem_wr_be = mem_wr_be_reg;
assign o_rdata = rdata_reg;
assign o_ready = ready_reg;

// address and data for the selected cache word
localparam WORDS_PER_BLOCK = BLOCK_SIZE / 4;
localparam WORD_OFFSET_BITS = BLOCK_OFFSET_BITS - 2;

wire [WORDS_PER_BLOCK-1:0] word_select;
wire [31:0] selected_word;
wire [31:0] hit_word_data;
wire [31:0] saved_word_data;

genvar word_number;
generate
    for (word_number = 0;
         word_number < WORDS_PER_BLOCK;
         word_number = word_number + 1) begin : gen_word_select

        assign word_select[word_number] =
            (i_addr[BLOCK_OFFSET_BITS-1:2] == word_number);

    end
endgenerate

// select the requested word from the hit line
wire [LINE_BITS-1:0] hit_line_data;
wire [LINE_BITS-1:0] saved_line_data;

assign hit_line_data = data_array[request_set][hit_way_index];
assign saved_line_data = data_array[saved_set][victim_way];

genvar read_word;
generate
    for (read_word = 0;
         read_word < WORDS_PER_BLOCK;
         read_word = read_word + 1) begin : gen_read_word

        assign selected_word[31:0] =
            (word_select[read_word])
            ? hit_line_data[read_word*32 +: 32]
            : 32'b0;

    end
endgenerate

// controller states
localparam STATE_IDLE = 3'd0;
localparam STATE_WRITEBACK = 3'd1;
localparam STATE_MEM_READ = 3'd2;
localparam STATE_REFILL = 3'd3;
localparam STATE_WRITE_THRU = 3'd4;

reg [2:0] controller_state;

// remember the selected cache way and aligned line address
reg [31:0] saved_block_addr;
reg [31:0] saved_victim_addr;
reg saved_store_miss;

// build a byte-masked write-through line
wire [LINE_BITS-1:0] store_line_data;
wire [BLOCK_SIZE-1:0] store_line_be;

genvar byte_number;
generate
    for (byte_number = 0;
         byte_number < BLOCK_SIZE;
         byte_number = byte_number + 1) begin : gen_store_line

        localparam BYTE_WORD = byte_number / 4;
        localparam BYTE_LANE = byte_number % 4;

        assign store_line_be[byte_number] =
            (saved_addr[BLOCK_OFFSET_BITS-1:2] == BYTE_WORD) &&
            saved_mask[BYTE_LANE];

        assign store_line_data[byte_number*8 +: 8] =
            saved_wdata[BYTE_LANE*8 +: 8];

    end
endgenerate

// request acceptance and memory transaction control
always @(posedge i_clk) begin
    if (i_rst) begin
        controller_state <= STATE_IDLE;
        mem_rd_reg <= 1'b0;
        mem_wr_reg <= 1'b0;
        mem_rd_addr_reg <= 32'b0;
        mem_wr_addr_reg <= 32'b0;
        mem_wr_data_reg <= {LINE_BITS{1'b0}};
        mem_wr_be_reg <= {BLOCK_SIZE{1'b0}};
        saved_addr <= 32'b0;
        saved_wdata <= 32'b0;
        saved_mask <= 4'b0;
        saved_ren <= 1'b0;
        saved_wen <= 1'b0;
        saved_set <= 32'b0;
        saved_tag <= {TAG_BITS{1'b0}};
        victim_way <= 32'b0;
        saved_block_addr <= 32'b0;
        saved_victim_addr <= 32'b0;
        saved_store_miss <= 1'b0;
        rdata_reg <= 32'b0;
        ready_reg <= 1'b1;
    end else begin
        mem_rd_reg <= 1'b0;
        mem_wr_reg <= 1'b0;
        ready_reg <= 1'b0;

        case (controller_state)
            STATE_IDLE: begin
                ready_reg <= 1'b1;

                if (i_ren || i_wen) begin
                    if (cache_hit) begin
                        if (i_ren) begin
                            rdata_reg <=
                                data_array[request_set][hit_way_index]
                                [i_addr[BLOCK_OFFSET_BITS-1:2]*32 +: 32];
                        end

                        if (i_wen) begin
                            controller_state <= STATE_IDLE;
                        end
                    end else begin
                        saved_addr <= i_addr;
                        saved_wdata <= i_wdata;
                        saved_mask <= i_mask;
                        saved_ren <= i_ren;
                        saved_wen <= i_wen;
                        saved_set <= request_set;
                        saved_tag <= request_tag;
                        saved_block_addr <= block_addr;
                        saved_store_miss <= i_wen && !cache_hit;
                        victim_way <=
                            i_wen ? 32'b0 : victim_way_index;

                        ready_reg <= 1'b0;

                        if (i_wen) begin
                            mem_wr_reg <= 1'b1;
                            mem_wr_addr_reg <= block_addr;
                            mem_wr_data_reg <= store_line_data;
                            mem_wr_be_reg <= store_line_be;
                            controller_state <= STATE_WRITE_THRU;
                        end else begin
                            saved_victim_addr <=
                                {tags[request_set][victim_way_index],
                                 request_set[INDEX_BITS-1:0],
                                 {BLOCK_OFFSET_BITS{1'b0}}};

                            if (!invalid_way_available &&
                                dirty[request_set][victim_way_index]) begin
                                mem_wr_reg <= 1'b1;
                                mem_wr_addr_reg <=
                                    {tags[request_set][victim_way_index],
                                     request_set[INDEX_BITS-1:0],
                                     {BLOCK_OFFSET_BITS{1'b0}}};
                                mem_wr_data_reg <=
                                    data_array[request_set][victim_way_index];
                                mem_wr_be_reg <= {BLOCK_SIZE{1'b1}};
                                controller_state <= STATE_WRITEBACK;
                            end else begin
                                mem_rd_reg <= 1'b1;
                                mem_rd_addr_reg <= block_addr;
                                controller_state <= STATE_MEM_READ;
                            end
                        end
                    end
                end
            end

            STATE_WRITEBACK: begin
                mem_rd_reg <= 1'b1;
                mem_rd_addr_reg <= saved_block_addr;
                controller_state <= STATE_MEM_READ;
            end

            STATE_MEM_READ: begin
                if (i_mem_valid) begin
                    controller_state <= STATE_REFILL;
                end
            end

            STATE_REFILL: begin
                controller_state <= STATE_IDLE;
                ready_reg <= 1'b1;
            end

            STATE_WRITE_THRU: begin
                controller_state <= STATE_IDLE;
                ready_reg <= 1'b1;
            end

            default: begin
                controller_state <= STATE_IDLE;
                ready_reg <= 1'b1;
            end
        endcase
    end
end

// update cache contents and replacement metadata
genvar set_number;
genvar cache_way;
generate
    for (set_number = 0;
         set_number < NUM_SETS;
         set_number = set_number + 1) begin : gen_cache_sets

        for (cache_way = 0;
             cache_way < NUM_WAYS;
             cache_way = cache_way + 1) begin : gen_cache_ways

            always @(posedge i_clk) begin
                if (i_rst) begin
                    tags[set_number][cache_way] <= {TAG_BITS{1'b0}};
                    valid[set_number][cache_way] <= 1'b0;
                    dirty[set_number][cache_way] <= 1'b0;
                    data_array[set_number][cache_way] <=
                        {LINE_BITS{1'b0}};
                    lru_age[set_number][cache_way] <=
                        {LRU_AGE_BITS{1'b0}};
                end else begin
                    if (controller_state == STATE_REFILL &&
                        saved_set == set_number &&
                        victim_way == cache_way) begin
                        tags[set_number][cache_way] <= saved_tag;
                        valid[set_number][cache_way] <= 1'b1;
                        dirty[set_number][cache_way] <= 1'b0;
                        data_array[set_number][cache_way] <= i_mem_rd_data;
                    end

                    if (controller_state == STATE_IDLE &&
                        cache_hit &&
                        request_set == set_number &&
                        hit_way_index == cache_way &&
                        i_wen) begin
                        if (i_mask[0])
                            data_array[set_number][cache_way]
                                [i_addr[BLOCK_OFFSET_BITS-1:2]*32 +: 8]
                                <= i_wdata[7:0];

                        if (i_mask[1])
                            data_array[set_number][cache_way]
                                [i_addr[BLOCK_OFFSET_BITS-1:2]*32+8 +: 8]
                                <= i_wdata[15:8];

                        if (i_mask[2])
                            data_array[set_number][cache_way]
                                [i_addr[BLOCK_OFFSET_BITS-1:2]*32+16 +: 8]
                                <= i_wdata[23:16];

                        if (i_mask[3])
                            data_array[set_number][cache_way]
                                [i_addr[BLOCK_OFFSET_BITS-1:2]*32+24 +: 8]
                                <= i_wdata[31:24];

                        dirty[set_number][cache_way] <= 1'b1;
                    end

                    if (controller_state == STATE_REFILL &&
                        saved_set == set_number &&
                        victim_way == cache_way) begin
                        if (saved_wen) begin
                            if (saved_mask[0])
                                data_array[set_number][cache_way]
                                    [saved_addr[BLOCK_OFFSET_BITS-1:2]*32 +: 8]
                                    <= saved_wdata[7:0];

                            if (saved_mask[1])
                                data_array[set_number][cache_way]
                                    [saved_addr[BLOCK_OFFSET_BITS-1:2]*32+8 +: 8]
                                    <= saved_wdata[15:8];

                            if (saved_mask[2])
                                data_array[set_number][cache_way]
                                    [saved_addr[BLOCK_OFFSET_BITS-1:2]*32+16 +: 8]
                                    <= saved_wdata[23:16];

                            if (saved_mask[3])
                                data_array[set_number][cache_way]
                                    [saved_addr[BLOCK_OFFSET_BITS-1:2]*32+24 +: 8]
                                    <= saved_wdata[31:24];

                            dirty[set_number][cache_way] <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endgenerate
    
endmodule

`default_nettype wire
