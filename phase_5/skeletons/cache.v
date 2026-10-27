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
localparam SET_BITS = (INDEX_BITS > 0) ? INDEX_BITS : 1;
localparam [31:0] BLOCK_SIZE_32 = BLOCK_SIZE;
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
wire [SET_BITS-1:0] request_set;
wire [31:0] block_addr;

// select address fields
generate
    if (INDEX_BITS == 0) begin : gen_fully_associative // fully associative
        assign request_tag = i_addr[31:BLOCK_OFFSET_BITS];
        assign request_set = {SET_BITS{1'b0}};
    end else begin : gen_indexed // indexed
        assign request_tag = i_addr[31:BLOCK_OFFSET_BITS+INDEX_BITS];
        assign request_set = i_addr[BLOCK_OFFSET_BITS +: INDEX_BITS];
    end
endgenerate

// clear offset bits for line-aligned address
assign block_addr = {i_addr[31:BLOCK_OFFSET_BITS],{BLOCK_OFFSET_BITS{1'b0}}};

// save CPU request
reg [31:0] saved_addr;
reg [31:0] saved_wdata;
reg [3:0] saved_mask;
reg saved_ren;
reg saved_wen;

// Word selection without multiplication and without an illegal [-1:0] slice
// when BLOCK_SIZE is the legal minimum of four bytes.
localparam WORD_INDEX_BITS =
    (BLOCK_OFFSET_BITS > 2) ? (BLOCK_OFFSET_BITS - 2) : 1;
wire [WORD_INDEX_BITS-1:0] request_word_index;
wire [WORD_INDEX_BITS-1:0] saved_word_index;
generate
    if (BLOCK_OFFSET_BITS == 2) begin : gen_single_word_line
        assign request_word_index = 0;
        assign saved_word_index = 0;
    end else begin : gen_multi_word_line
        assign request_word_index = i_addr[BLOCK_OFFSET_BITS-1:2];
        assign saved_word_index = saved_addr[BLOCK_OFFSET_BITS-1:2];
    end
endgenerate
wire [WORD_INDEX_BITS+4:0] request_bit_offset;
wire [WORD_INDEX_BITS+4:0] saved_bit_offset;
assign request_bit_offset = {request_word_index, 5'b00000};
assign saved_bit_offset = {saved_word_index, 5'b00000};

// Controller state declarations are below, next to the memory-control logic.

// one-hot way selection width; declare before any vectors that use it
localparam WAY_BITS_RAW = $clog2(NUM_WAYS);
localparam WAY_BITS = (WAY_BITS_RAW == 0) ? 1 : WAY_BITS_RAW;

// remember set and way serviced
reg [SET_BITS-1:0] saved_set;
reg [TAG_BITS-1:0] saved_tag;
reg [WAY_BITS-1:0] victim_way;

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

// one-hot way selection for index bits
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
            localparam [0:0] BIT_VALUE = (WAY_NUMBER / (2 ** way_bit)) % 2;
            assign hit_terms[w] = first_hit[w] & BIT_VALUE;
            assign invalid_terms[w] = first_invalid[w] & BIT_VALUE;
        end
        assign hit_way_index[way_bit] = |hit_terms;
        assign invalid_way_index[way_bit] = |invalid_terms;
    end
endgenerate

 // LRU and PLRU implementation
 // lower age means more recently used
 localparam LRU_AGE_BITS_RAW = $clog2(NUM_WAYS);
 localparam LRU_AGE_BITS =
     (LRU_AGE_BITS_RAW == 0) ? 1 : LRU_AGE_BITS_RAW;
 localparam [LRU_AGE_BITS-1:0] MAX_LRU_AGE = NUM_WAYS - 1;

 // One direction bit per internal node of the replacement tree.
 // Tree-PLRU is implemented for the balanced tree sizes used by this design:
 // one, two and four ways. Other associativities select the exact-LRU victim;
 // this avoids silently indexing nonexistent PLRU nodes.
 localparam PLRU_NODES = NUM_WAYS - 1;

 // The PDF requires at least one replacement policy for every legal cache
 // configuration. Exact LRU is supported for every NUM_WAYS. The additional
 // tree-PLRU implementation is enabled for balanced 2-way and 4-way trees,
 // including the PDF's illustrated 4-way organization.
 localparam USE_TREE_PLRU =
     (EVICT_POLICY == 1) && ((NUM_WAYS == 2) || (NUM_WAYS == 4));

 reg [LRU_AGE_BITS-1:0] lru_age [0:NUM_SETS-1][0:NUM_WAYS-1];

 reg [((PLRU_NODES > 0) ? PLRU_NODES : 1)-1:0] plru_bits [0:NUM_SETS-1];

 // victim/replacement selection
 // invalid lines take priority over the replacement policy
 wire [WAY_BITS-1:0] victim_way_index;
 wire [WAY_BITS-1:0] policy_victim_way;
 wire [WAY_BITS-1:0] lru_victim_index;

 // Line-aligned address of the currently selected demand victim. The
 // generate split avoids request_set[-1:0] in fully associative mode.
 wire [31:0] selected_victim_addr;
 generate
     if (INDEX_BITS == 0) begin : gen_selected_victim_addr_fa
         assign selected_victim_addr =
             {tags[request_set][victim_way_index],
              {BLOCK_OFFSET_BITS{1'b0}}};
     end else begin : gen_selected_victim_addr_indexed
         assign selected_victim_addr =
             {tags[request_set][victim_way_index],
              request_set[INDEX_BITS-1:0],
              {BLOCK_OFFSET_BITS{1'b0}}};
     end
 endgenerate

 // choose the lowest-numbered invalid way when available
 assign victim_way_index = invalid_way_available
                         ? invalid_way_index
                         : policy_victim_way;

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

             localparam [0:0] VICTIM_BIT_VALUE =
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

        if (NUM_WAYS == 1) begin

            assign policy_victim_way = 0;

        end else if (NUM_WAYS == 2) begin

            assign policy_victim_way =
                plru_bits[request_set][0];

        end else if (NUM_WAYS == 4) begin

            assign policy_victim_way =
                !plru_bits[request_set][0] ?
                    (
                        !plru_bits[request_set][1] ?
                            2'd0 : 2'd1
                    )
                    :
                    (
                        !plru_bits[request_set][2] ?
                            2'd2 : 2'd3
                    );

        end else begin

            assign policy_victim_way =
                lru_victim_index;

        end
    end
 endgenerate

// Controller states and state register must be declared before any
// continuous assignment references them (`default_nettype none`).
localparam STATE_IDLE         = 3'd0;
localparam STATE_WRITEBACK    = 3'd1;
localparam STATE_MEM_READ     = 3'd2;
localparam STATE_REFILL       = 3'd4;
localparam STATE_PREFETCH_REQ = 3'd7;
reg [2:0] controller_state;

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
wire [31:0] hit_word;
assign hit_word =
    data_array[request_set][hit_way_index]
    [request_bit_offset +: 32];
wire [31:0] demand_return_word;
assign demand_return_word =
    i_mem_rd_data[saved_bit_offset +: 32];

assign o_rdata =
    (controller_state == STATE_REFILL)
        ? rdata_reg
        : (cache_hit ? hit_word : rdata_reg);

// Two ordered read-response entries are represented by controller state plus
// this second-entry flag. STATE_MEM_READ tracks the demand response; when set,
// prefetch_outstanding tracks the immediately following prefetch response.
// Memory responses are in request order, as required by the project interface.
reg prefetch_outstanding;
reg [31:0] prefetch_block_addr;
reg saved_do_prefetch;

wire [31:0] next_block_addr;
assign next_block_addr = block_addr + BLOCK_SIZE_32;
wire [SET_BITS-1:0] next_set;
wire [TAG_BITS-1:0] next_tag;
generate
    if (INDEX_BITS == 0) begin : gen_next_fa
        assign next_set = {SET_BITS{1'b0}};
        assign next_tag = next_block_addr[31:BLOCK_OFFSET_BITS];
    end else begin : gen_next_indexed
        assign next_set = next_block_addr[BLOCK_OFFSET_BITS +: INDEX_BITS];
        assign next_tag = next_block_addr[31:BLOCK_OFFSET_BITS+INDEX_BITS];
    end
endgenerate
wire [NUM_WAYS-1:0] next_hit_vec;
genvar next_way;
generate
    for (next_way = 0; next_way < NUM_WAYS; next_way = next_way + 1) begin : gen_next_hit
        assign next_hit_vec[next_way] = valid[next_set][next_way] &&
                                        tags[next_set][next_way] == next_tag;
    end
endgenerate
wire next_line_cached;
assign next_line_cached = |next_hit_vec;

wire [SET_BITS-1:0] pf_set;
wire [TAG_BITS-1:0] pf_tag;
generate
    if (INDEX_BITS == 0) begin : gen_pf_fa
        assign pf_set = {SET_BITS{1'b0}};
        assign pf_tag = prefetch_block_addr[31:BLOCK_OFFSET_BITS];
    end else begin : gen_pf_indexed
        assign pf_set = prefetch_block_addr[BLOCK_OFFSET_BITS +: INDEX_BITS];
        assign pf_tag = prefetch_block_addr[31:BLOCK_OFFSET_BITS+INDEX_BITS];
    end
endgenerate
wire [NUM_WAYS-1:0] pf_hit_vec;
wire [NUM_WAYS-1:0] pf_invalid_vec;
genvar pfw;
generate
    for (pfw = 0; pfw < NUM_WAYS; pfw = pfw + 1) begin : gen_pf_lookup
        assign pf_hit_vec[pfw] = valid[pf_set][pfw] && tags[pf_set][pfw] == pf_tag;
        assign pf_invalid_vec[pfw] = !valid[pf_set][pfw];
    end
endgenerate
wire pf_cache_hit;
wire pf_invalid_available;
assign pf_cache_hit = |pf_hit_vec;
assign pf_invalid_available = |pf_invalid_vec;

// Arrival-time victim selection, built entirely with generate loops and
// continuous assignments so it obeys the course combinational-logic rules.
wire [NUM_WAYS:0] pf_invalid_seen;
wire [NUM_WAYS-1:0] pf_first_invalid;
assign pf_invalid_seen[0] = 1'b0;
genvar pf_first_way;
generate
    for (pf_first_way = 0; pf_first_way < NUM_WAYS;
         pf_first_way = pf_first_way + 1) begin : gen_pf_first_invalid
        assign pf_first_invalid[pf_first_way] =
            pf_invalid_vec[pf_first_way] && !pf_invalid_seen[pf_first_way];
        assign pf_invalid_seen[pf_first_way+1] =
            pf_invalid_seen[pf_first_way] || pf_invalid_vec[pf_first_way];
    end
endgenerate

wire [WAY_BITS-1:0] pf_invalid_index;
genvar pf_invalid_bit;
generate
    for (pf_invalid_bit = 0; pf_invalid_bit < WAY_BITS;
         pf_invalid_bit = pf_invalid_bit + 1) begin : gen_pf_invalid_index
        wire [NUM_WAYS-1:0] terms;
        genvar pf_invalid_number;
        for (pf_invalid_number = 0; pf_invalid_number < NUM_WAYS;
             pf_invalid_number = pf_invalid_number + 1) begin : gen_terms
            localparam [0:0] V = (pf_invalid_number / (2 ** pf_invalid_bit)) % 2;
            assign terms[pf_invalid_number] = pf_first_invalid[pf_invalid_number] & V;
        end
        assign pf_invalid_index[pf_invalid_bit] = |terms;
    end
endgenerate

wire [NUM_WAYS-1:0] pf_lru_onehot;
genvar pf_candidate;
generate
    for (pf_candidate = 0; pf_candidate < NUM_WAYS;
         pf_candidate = pf_candidate + 1) begin : gen_pf_lru
        wire [NUM_WAYS-1:0] older;
        genvar pf_compare;
        for (pf_compare = 0; pf_compare < NUM_WAYS;
             pf_compare = pf_compare + 1) begin : gen_compare
            if (pf_compare == pf_candidate) begin : gen_same
                assign older[pf_compare] = 1'b0;
            end else begin : gen_other
                assign older[pf_compare] =
                    valid[pf_set][pf_compare] &&
                    ((lru_age[pf_set][pf_compare] > lru_age[pf_set][pf_candidate]) ||
                     ((lru_age[pf_set][pf_compare] == lru_age[pf_set][pf_candidate]) &&
                      (pf_compare < pf_candidate)));
            end
        end
        assign pf_lru_onehot[pf_candidate] =
            valid[pf_set][pf_candidate] && !(|older);
    end
endgenerate

wire [WAY_BITS-1:0] pf_lru_index;
genvar pf_lru_bit;
generate
    for (pf_lru_bit = 0; pf_lru_bit < WAY_BITS;
         pf_lru_bit = pf_lru_bit + 1) begin : gen_pf_lru_index
        wire [NUM_WAYS-1:0] terms;
        genvar pf_number;
        for (pf_number = 0; pf_number < NUM_WAYS;
             pf_number = pf_number + 1) begin : gen_terms
            localparam [0:0] V = (pf_number / (2 ** pf_lru_bit)) % 2;
            assign terms[pf_number] = pf_lru_onehot[pf_number] & V;
        end
        assign pf_lru_index[pf_lru_bit] = |terms;
    end
endgenerate

wire [WAY_BITS-1:0] pf_plru_index;
generate
    if (NUM_WAYS == 1) begin : gen_pf_plru_1
        assign pf_plru_index = 0;
    end else if (NUM_WAYS == 2) begin : gen_pf_plru_2
        assign pf_plru_index = plru_bits[pf_set][0];
    end else if (NUM_WAYS == 4) begin : gen_pf_plru_4
        assign pf_plru_index = !plru_bits[pf_set][0] ?
            (!plru_bits[pf_set][1] ? 2'd0 : 2'd1) :
            (!plru_bits[pf_set][2] ? 2'd2 : 2'd3);
    end else begin : gen_pf_plru_fallback
        assign pf_plru_index = pf_lru_index;
    end
endgenerate

wire [WAY_BITS-1:0] pf_policy_index;
assign pf_policy_index =
    USE_TREE_PLRU ? pf_plru_index : pf_lru_index;
wire [WAY_BITS-1:0] pf_victim_way;
assign pf_victim_way = pf_invalid_available ? pf_invalid_index : pf_policy_index;


wire [31:0] pf_victim_addr;
generate
    if (INDEX_BITS == 0) begin : gen_pf_victim_fa
        assign pf_victim_addr = {tags[pf_set][pf_victim_way],
                                 {BLOCK_OFFSET_BITS{1'b0}}};
    end else begin : gen_pf_victim_indexed
        assign pf_victim_addr = {tags[pf_set][pf_victim_way],
                                 pf_set[INDEX_BITS-1:0],
                                 {BLOCK_OFFSET_BITS{1'b0}}};
    end
endgenerate

reg pf_fill_valid;
reg [LINE_BITS-1:0] pf_fill_data;
reg [SET_BITS-1:0] pf_fill_set;
reg [TAG_BITS-1:0] pf_fill_tag;
reg [WAY_BITS-1:0] pf_fill_way;

wire [1:0] pf_fill_way_case;
wire [1:0] victim_way_case;
wire [1:0] hit_way_case;
generate
    if (WAY_BITS == 1) begin : gen_case_way_1
        assign pf_fill_way_case = {1'b0, pf_fill_way};
        assign victim_way_case = {1'b0, victim_way};
        assign hit_way_case = {1'b0, hit_way_index};
    end else begin : gen_case_way_n
        assign pf_fill_way_case = pf_fill_way[1:0];
        assign victim_way_case = victim_way[1:0];
        assign hit_way_case = hit_way_index[1:0];
    end
endgenerate

// remember the selected cache way and aligned line address
reg [31:0] saved_block_addr;
reg [31:0] saved_victim_addr;

// build a byte-masked write-through line
wire [LINE_BITS-1:0] store_line_data;
wire [BLOCK_SIZE-1:0] store_line_be;

// refill buffer
reg [LINE_BITS-1:0] refill_line;

genvar byte_number;
generate
    for (byte_number = 0;
         byte_number < BLOCK_SIZE;
         byte_number = byte_number + 1) begin : gen_store_line

        localparam [WORD_INDEX_BITS-1:0] BYTE_WORD_INDEX =
            byte_number / 4;
        localparam BYTE_LANE = byte_number % 4;

        assign store_line_be[byte_number] =
            (request_word_index == BYTE_WORD_INDEX) &&
            i_mask[BYTE_LANE];

        assign store_line_data[byte_number*8 +: 8] =
            i_wdata[BYTE_LANE*8 +: 8];

    end
endgenerate

// In IDLE, readiness must reflect the current request combinationally.
// A registered ready value from reset would otherwise let the hart consume
// rdata_reg (zero) on the first miss before the memory line has arrived.
assign o_ready =
    (controller_state == STATE_REFILL)
        ? 1'b1
        : ((controller_state == STATE_IDLE)
            ? (!(prefetch_outstanding && i_mem_valid) &&
               (!(i_ren || i_wen) || i_wen || cache_hit))
            : ready_reg);

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
        saved_set <= {SET_BITS{1'b0}};
        saved_tag <= {TAG_BITS{1'b0}};
        victim_way <= {WAY_BITS{1'b0}};
        saved_block_addr <= 32'b0;
        saved_victim_addr <= 32'b0;
        prefetch_outstanding <= 1'b0;
        prefetch_block_addr <= 32'b0;
        saved_do_prefetch <= 1'b0;
        pf_fill_valid <= 1'b0;
        pf_fill_data <= {LINE_BITS{1'b0}};
        pf_fill_set <= {SET_BITS{1'b0}};
        pf_fill_tag <= {TAG_BITS{1'b0}};
        pf_fill_way <= 0;
        rdata_reg <= 32'b0;
        ready_reg <= 1'b1;
    end else begin
        mem_rd_reg <= 1'b0;
        mem_wr_reg <= 1'b0;
        ready_reg <= 1'b0;
        pf_fill_valid <= 1'b0;

        case (controller_state)
            STATE_IDLE: begin
                ready_reg <= 1'b1;

                if (prefetch_outstanding && i_mem_valid) begin
                    // Collision option B: prefetch update has priority.
                    ready_reg <= 1'b0;
                    prefetch_outstanding <= 1'b0;
                    if (!pf_cache_hit) begin
                        if (!pf_invalid_available && dirty[pf_set][pf_victim_way]) begin
                            mem_wr_reg <= 1'b1;
                            mem_wr_addr_reg <= pf_victim_addr;
                            mem_wr_data_reg <= data_array[pf_set][pf_victim_way];
                            mem_wr_be_reg <= {BLOCK_SIZE{1'b1}};
                        end
                        pf_fill_valid <= 1'b1;
                        pf_fill_data <= i_mem_rd_data;
                        pf_fill_set <= pf_set;
                        pf_fill_tag <= pf_tag;
                        pf_fill_way <= pf_victim_way;
                    end
                end else if (i_ren || i_wen) begin
                    // Hits may proceed while a prefetch is outstanding. A new
                    // miss waits so in-order memory responses cannot be confused.
                    if (prefetch_outstanding && !cache_hit) begin
                        ready_reg <= 1'b0;
                    end else begin
                        if (cache_hit) begin
                            if (i_ren) begin
                                rdata_reg <=
                                    data_array[request_set][hit_way_index]
                                    [request_bit_offset +: 32];
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
                        saved_do_prefetch <= PREFETCH_EN && i_ren && !next_line_cached;
                        victim_way <=
                            i_wen ? {WAY_BITS{1'b0}} : victim_way_index;

                        ready_reg <= 1'b0;

                        if (i_wen) begin
                            mem_wr_reg <= 1'b1;
                            mem_wr_addr_reg <= block_addr;
                            mem_wr_data_reg <= store_line_data;
                            mem_wr_be_reg <= store_line_be;
                            // Main-memory writes have no response/stall.
                            // Complete the write-through store in this cycle.
                            controller_state <= STATE_IDLE;
                        end else begin
                            saved_victim_addr <=
                                selected_victim_addr;

                            if (!invalid_way_available &&
                                dirty[request_set][victim_way_index]) begin
                                mem_wr_reg <= 1'b1;
                                mem_wr_addr_reg <=
                                    selected_victim_addr;
                                mem_wr_data_reg <=
                                    data_array[request_set][victim_way_index];
                                mem_wr_be_reg <= {BLOCK_SIZE{1'b1}};
                                controller_state <= STATE_WRITEBACK;
                            end else begin
                                mem_rd_reg <= 1'b1;
                                mem_rd_addr_reg <= block_addr;
                                if (PREFETCH_EN && i_ren && !next_line_cached) begin
                                    prefetch_block_addr <= block_addr + BLOCK_SIZE_32;
                                    controller_state <= STATE_PREFETCH_REQ;
                                end else begin
                                    controller_state <= STATE_MEM_READ;
                                end
                            end
                        end
                    end
                    end
                end
            end

            STATE_WRITEBACK: begin
                mem_rd_reg <= 1'b1;
                mem_rd_addr_reg <= saved_block_addr;
                if (saved_do_prefetch) begin
                    prefetch_block_addr <= saved_block_addr + BLOCK_SIZE_32;
                    controller_state <= STATE_PREFETCH_REQ;
                end else begin
                    controller_state <= STATE_MEM_READ;
                end
            end

            STATE_PREFETCH_REQ: begin
                mem_rd_reg <= 1'b1;
                mem_rd_addr_reg <= prefetch_block_addr;
                prefetch_outstanding <= 1'b1;
                controller_state <= STATE_MEM_READ;
            end
            STATE_MEM_READ: begin
                if (i_mem_valid) begin
                    // Capture the demand response on its arrival edge. In the
                    // cycle immediately following that edge, STATE_REFILL
                    // presents stable ready/data and the stalled load finishes.
                    // This is the synchronous interpretation of the PDF's
                    // "demand line arrives; load finishes" timeline.
                    refill_line <= i_mem_rd_data;
                    rdata_reg <= demand_return_word;
                    controller_state <= STATE_REFILL;
                end
            end

            STATE_REFILL: begin
                // The demand operation completes in this response cycle. The
                // next in-order response may simultaneously be the prefetched
                // line; it is captured without extending the demand stall.
                if (prefetch_outstanding && i_mem_valid) begin
                    prefetch_outstanding <= 1'b0;
                    if (!pf_cache_hit) begin
                        if (!pf_invalid_available &&
                            dirty[pf_set][pf_victim_way]) begin
                            mem_wr_reg <= 1'b1;
                            mem_wr_addr_reg <= pf_victim_addr;
                            mem_wr_data_reg <=
                                data_array[pf_set][pf_victim_way];
                            mem_wr_be_reg <= {BLOCK_SIZE{1'b1}};
                        end
                        pf_fill_valid <= 1'b1;
                        pf_fill_data <= i_mem_rd_data;
                        pf_fill_set <= pf_set;
                        pf_fill_tag <= pf_tag;
                        pf_fill_way <= pf_victim_way;
                    end
                end
                controller_state <= STATE_IDLE;
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

        // Exactly one sequential writer owns the PLRU state for this set.
        // Priority matches cache-array update priority: returning prefetch,
        // demand refill, then an ordinary CPU hit.
        always @(posedge i_clk) begin
            if (i_rst) begin
                plru_bits[set_number] <= 0;
            end else begin
                if (EVICT_POLICY == 1 && pf_fill_valid &&
                    pf_fill_set == set_number) begin
                    if (NUM_WAYS == 2) begin
                        plru_bits[set_number][0] <= ~pf_fill_way[0];
                    end else if (NUM_WAYS == 4) begin
                        case (pf_fill_way_case)
                            2'd0: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b1;
                            end
                            2'd1: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b0;
                            end
                            2'd2: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b1;
                            end
                            2'd3: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b0;
                            end
                            default: begin
                                plru_bits[set_number] <= plru_bits[set_number];
                            end
                        endcase
                    end
                end else if (EVICT_POLICY == 1 &&
                             controller_state == STATE_REFILL &&
                             saved_set == set_number) begin
                    if (NUM_WAYS == 2) begin
                        plru_bits[set_number][0] <= ~victim_way[0];
                    end else if (NUM_WAYS == 4) begin
                        case (victim_way_case)
                            2'd0: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b1;
                            end
                            2'd1: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b0;
                            end
                            2'd2: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b1;
                            end
                            2'd3: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b0;
                            end
                            default: begin
                                plru_bits[set_number] <= plru_bits[set_number];
                            end
                        endcase
                    end
                end else if (EVICT_POLICY == 1 &&
                             controller_state == STATE_IDLE &&
                             !pf_fill_valid && cache_hit &&
                             request_set == set_number) begin
                    if (NUM_WAYS == 2) begin
                        plru_bits[set_number][0] <= ~hit_way_index[0];
                    end else if (NUM_WAYS == 4) begin
                        case (hit_way_case)
                            2'd0: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b1;
                            end
                            2'd1: begin
                                plru_bits[set_number][0] <= 1'b1;
                                plru_bits[set_number][1] <= 1'b0;
                            end
                            2'd2: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b1;
                            end
                            2'd3: begin
                                plru_bits[set_number][0] <= 1'b0;
                                plru_bits[set_number][2] <= 1'b0;
                            end
                            default: begin
                                plru_bits[set_number] <= plru_bits[set_number];
                            end
                        endcase
                    end
                end
            end
        end

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
                    // One procedural writer per age register. A hit/fill moves
                    // the selected way to MRU (age zero) while preserving the
                    // exact relative order of all more-recent ways.
                    if (!USE_TREE_PLRU && pf_fill_valid &&
                        pf_fill_set == set_number) begin
                        if (pf_fill_way == cache_way)
                            lru_age[set_number][cache_way] <= 0;
                        else if (valid[set_number][cache_way] &&
                                 lru_age[set_number][cache_way] < MAX_LRU_AGE)
                            lru_age[set_number][cache_way] <=
                                lru_age[set_number][cache_way] + 1'b1;
                    end else if (!USE_TREE_PLRU &&
                                 controller_state == STATE_REFILL &&
                                 saved_set == set_number) begin
                        if (victim_way == cache_way)
                            lru_age[set_number][cache_way] <= 0;
                        else if (valid[set_number][cache_way] &&
                                 lru_age[set_number][cache_way] < MAX_LRU_AGE)
                            lru_age[set_number][cache_way] <=
                                lru_age[set_number][cache_way] + 1'b1;
                    end else if (!USE_TREE_PLRU &&
                                 controller_state == STATE_IDLE &&
                                 !pf_fill_valid && cache_hit &&
                                 request_set == set_number) begin
                        if (hit_way_index == cache_way)
                            lru_age[set_number][cache_way] <= 0;
                        else if (valid[set_number][cache_way] &&
                                 lru_age[set_number][cache_way] <
                                    lru_age[request_set][hit_way_index])
                            lru_age[set_number][cache_way] <=
                                lru_age[set_number][cache_way] + 1'b1;
                    end

                    if (controller_state == STATE_REFILL &&
                        saved_set == set_number &&
                        victim_way == cache_way) begin


                        tags[set_number][cache_way] <= saved_tag;
                        valid[set_number][cache_way] <= 1'b1;
                        dirty[set_number][cache_way] <= 1'b0;
                        data_array[set_number][cache_way] <= refill_line;
                    end

                    if (pf_fill_valid &&
                        pf_fill_set == set_number &&
                        pf_fill_way == cache_way) begin
                        tags[set_number][cache_way] <= pf_fill_tag;
                        valid[set_number][cache_way] <= 1'b1;
                        dirty[set_number][cache_way] <= 1'b0;
                        data_array[set_number][cache_way] <= pf_fill_data;
                    end
                    if (controller_state == STATE_IDLE &&
                        !pf_fill_valid &&
                        cache_hit &&
                        request_set == set_number &&
                        hit_way_index == cache_way) begin

                        if (i_wen) begin
                            if (i_mask[0])
                                data_array[set_number][cache_way]
                                    [request_bit_offset +: 8]
                                    <= i_wdata[7:0];

                            if (i_mask[1])
                                data_array[set_number][cache_way]
                                    [request_bit_offset+8 +: 8]
                                    <= i_wdata[15:8];

                            if (i_mask[2])
                                data_array[set_number][cache_way]
                                    [request_bit_offset+16 +: 8]
                                    <= i_wdata[23:16];

                            if (i_mask[3])
                                data_array[set_number][cache_way]
                                    [request_bit_offset+24 +: 8]
                                    <= i_wdata[31:24];

                            dirty[set_number][cache_way] <= 1'b1;
                        end
                    end

                    if (controller_state == STATE_REFILL &&
                        saved_set == set_number &&
                        victim_way == cache_way) begin
                        if (saved_wen) begin
                            if (saved_mask[0])
                                data_array[set_number][cache_way]
                                    [saved_bit_offset +: 8]
                                    <= saved_wdata[7:0];

                            if (saved_mask[1])
                                data_array[set_number][cache_way]
                                    [saved_bit_offset+8 +: 8]
                                    <= saved_wdata[15:8];

                            if (saved_mask[2])
                                data_array[set_number][cache_way]
                                    [saved_bit_offset+16 +: 8]
                                    <= saved_wdata[23:16];

                            if (saved_mask[3])
                                data_array[set_number][cache_way]
                                    [saved_bit_offset+24 +: 8]
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
