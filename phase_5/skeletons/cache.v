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
localparam LRU_AGE_BITS = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS); // lower is most recently used
localparam PLRU_NODES = NUM_WAYS - 1; // one direction bit per internal node of bin tree

reg [LRU_AGE_BITS-1:0] lru_age [0:NUM_SETS-1][0:NUM_WAYS-1];

reg plru_bits [0:NUM_SETS-1][0:((PLRU_NODES > 0) ? PLRU_NODES-1 : 0)]; // one entry per set and internal tree node, allocate unused entry for direct-mapped cache

// victim/replacement selection
// invalid lines > replacement policy
wire [WAY_BITS-1:0] victim_way_index;
wire victim_is_invalid;
wire [WAY_BITS-1:0] policy_victim_way; // victim when all ways in set valid

// prefer lowest invalid way
assign victim_way_index = invalid_way_available ? invalid_way_index : policy_victim_way;
assign victim_is_invalid = invalid_way_available;
    
endmodule

`default_nettype wire
