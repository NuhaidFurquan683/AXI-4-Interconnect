`timescale 1ns/1ps
// =============================================================================
// Synthesizable AXI4 block-RAM slave (hardware test)
// =============================================================================
// - 4 KB (1024 x 32) simple-dual-port block RAM with byte-write enables
// - FIXED / INCR / WRAP bursts, one write and one read in flight
// - Full-throughput read pipeline: one R beat per cycle when RREADY is high
// - stall_en: random AWREADY / WREADY / ARREADY / R-beat stalls (LFSR)
// - route_err (sticky): an address arrived whose top bits are not SIDX,
//   i.e. the crossbar routed a transaction to the wrong slave
// =============================================================================
module axi_bram_slave #(
    parameter int          SIDX      = 0,
    parameter int          ID_WIDTH  = 4,
    parameter int          MEM_WORDS = 1024,
    parameter logic [31:0] SEED      = 32'hCAFE_F00D
)(
    input  logic   clk,
    input  logic   rst_n,
    input  logic   stall_en,
    axi4_if.slave  s,
    output logic   route_err
);

    localparam int AW = $clog2(MEM_WORDS);
    localparam logic [1:0] FIXED = 2'b00, WRAP = 2'b10;

    function automatic logic [31:0] next_addr(logic [31:0] a, logic [7:0] len, logic [1:0] burst);
        logic [31:0] mask;
        mask = {22'b0, len, 2'b11};
        case (burst)
            FIXED:   return a;
            WRAP:    return (a & ~mask) | ((a + 32'd4) & mask);
            default: return {a[31:2] + 30'd1, 2'b00};
        endcase
    endfunction

    // ---------------------------------------------------------------- LFSR
    logic [31:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= SEED;
        else        lfsr <= {1'b0, lfsr[31:1]} ^ (lfsr[0] ? 32'h8020_0003 : 32'h0);
    end
    logic st_aw, st_w, st_ar, st_r;
    assign st_aw = stall_en && (lfsr[1:0]   == 2'b00);
    assign st_w  = stall_en && (lfsr[9:8]   == 2'b00);
    assign st_ar = stall_en && (lfsr[17:16] == 2'b00);
    assign st_r  = stall_en && (lfsr[25:24] == 2'b00);

    // ---------------------------------------------------------------- memory
    (* ram_style = "block" *) logic [31:0] mem [MEM_WORDS];   // force block RAM (not LUTRAM)
    logic          we, re;
    logic [AW-1:0] widx, ridx;
    logic [31:0]   rd_q;

    always_ff @(posedge clk) begin
        for (int b = 0; b < 4; b++)
            if (we && s.wstrb[b]) mem[widx][8*b +: 8] <= s.wdata[8*b +: 8];
    end
    always_ff @(posedge clk) begin
        if (re) rd_q <= mem[ridx];
    end

    // ---------------------------------------------------------------- write side
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_t;
    wst_t                wst;
    logic [31:0]         w_addr;
    logic [7:0]          w_len;
    logic [1:0]          w_burst;
    logic [ID_WIDTH-1:0] w_id;

    assign s.awready = (wst == W_IDLE) && !st_aw;
    assign s.wready  = (wst == W_DATA) && !st_w;
    assign s.bvalid  = (wst == W_RESP);
    assign s.bid     = w_id;
    assign s.bresp   = 2'b00;

    assign we   = s.wvalid && s.wready;
    assign widx = w_addr[AW+1:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; w_addr <= '0; w_len <= '0; w_burst <= '0; w_id <= '0;
            route_err <= 1'b0;
        end else begin
            case (wst)
                W_IDLE: if (s.awvalid && s.awready) begin
                    w_addr  <= s.awaddr;
                    w_len   <= s.awlen;
                    w_burst <= s.awburst;
                    w_id    <= s.awid;
                    if (s.awaddr[31:30] != 2'(SIDX)) route_err <= 1'b1;
                    wst     <= W_DATA;
                end
                W_DATA: if (we) begin
                    w_addr <= next_addr(w_addr, w_len, w_burst);
                    if (s.wlast) wst <= W_RESP;
                end
                W_RESP: if (s.bready) wst <= W_IDLE;
                default: wst <= W_IDLE;
            endcase
            if (s.arvalid && s.arready && s.araddr[31:30] != 2'(SIDX)) route_err <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- read side
    logic                r_busy, rvalid_q, rlast_q, last_issued;
    logic [31:0]         r_addr;
    logic [7:0]          r_len, r_cnt;
    logic [1:0]          r_burst;
    logic [ID_WIDTH-1:0] r_id;

    assign s.arready = !r_busy && !st_ar;
    assign s.rvalid  = rvalid_q;
    assign s.rlast   = rlast_q;
    assign s.rdata   = rd_q;
    assign s.rid     = r_id;
    assign s.rresp   = 2'b00;

    // Issue the next BRAM read when the output register is free or being consumed
    assign re   = r_busy && !last_issued && (!rvalid_q || s.rready) && !st_r;
    assign ridx = r_addr[AW+1:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_busy <= 1'b0; rvalid_q <= 1'b0; rlast_q <= 1'b0; last_issued <= 1'b0;
            r_addr <= '0; r_len <= '0; r_cnt <= '0; r_burst <= '0; r_id <= '0;
        end else begin
            if (s.arvalid && s.arready) begin
                r_busy      <= 1'b1;
                r_addr      <= s.araddr;
                r_len       <= s.arlen;
                r_burst     <= s.arburst;
                r_id        <= s.arid;
                r_cnt       <= '0;
                last_issued <= 1'b0;
            end
            if (re) begin
                rvalid_q <= 1'b1;
                rlast_q  <= (r_cnt == r_len);
                if (r_cnt == r_len) last_issued <= 1'b1;
                r_cnt    <= r_cnt + 8'd1;
                r_addr   <= next_addr(r_addr, r_len, r_burst);
            end else if (rvalid_q && s.rready) begin
                rvalid_q <= 1'b0;
            end
            if (rvalid_q && s.rready && rlast_q) begin
                r_busy      <= 1'b0;
                rvalid_q    <= 1'b0;
                rlast_q     <= 1'b0;
                last_issued <= 1'b0;
            end
        end
    end

endmodule
