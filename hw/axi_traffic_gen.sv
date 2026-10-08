`timescale 1ns/1ps
// =============================================================================
// Synthesizable AXI4 traffic generator + self-checker (hardware test)
// =============================================================================
// Loop while `run` is high:
//   1. pick a random slave, block, start offset, burst type (INCR / WRAP /
//      FIXED), length and ID (32-bit LFSR)
//   2. write the burst (AW and W driven concurrently, W may lead AW)
//   3. check B: BID matches, BRESP = OKAY (DECERR for an unmapped target)
//   4. read the same burst back and check RID, RRESP, RLAST position and
//      every data word
// Data written to a word = {epoch[15:0], addr[31:30], addr[13:0]}, so a word
// that was routed to the wrong slave, the wrong master region, or not written
// at all reads back with the wrong value.
//
// Address map used by master MIDX (each master owns a private 2 KB region in
// every slave, so the two generators never touch the same words):
//   [31:30] slave select (3 = unmapped -> DECERR)  [11] MIDX
//   [10:6]  block (64 bytes)  [5:2] word in block
// stall_en  : random BREADY / RREADY deassertion and gaps between W beats
// decerr_en : every 64th transaction targets the unmapped region
// =============================================================================
module axi_traffic_gen #(
    parameter int          MIDX     = 0,
    parameter int          ID_WIDTH = 4,
    parameter logic [31:0] SEED     = 32'h1234_5678
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        run,
    input  logic        stall_en,
    input  logic        decerr_en,
    input  logic        clear,          // zero counters and sticky error flags

    axi4_if.master      m,

    output logic        idle,
    output logic [31:0] txn_count,      // completed write+readback pairs
    output logic [31:0] aw_count,       // AW handshakes (all, incl. DECERR)
    output logic [31:0] ar_count,       // AR handshakes (all, incl. DECERR)
    output logic [31:0] decerr_count,   // DECERR responses seen (B + R)
    output logic [31:0] err_count,      // total check failures
    output logic        err_data,       // sticky: read data mismatch
    output logic        err_resp,       // sticky: wrong BRESP/RRESP
    output logic        err_proto,      // sticky: wrong ID or RLAST position
    output logic        beat_w,         // pulse: W beat accepted
    output logic        beat_r          // pulse: R beat accepted
);

    localparam logic [1:0] FIXED = 2'b00, INCR = 2'b01, WRAP = 2'b10;
    localparam logic [1:0] OKAY  = 2'b00, DECERR = 2'b11;

    // ---------------------------------------------------------------- helpers
    function automatic logic [31:0] next_addr(logic [31:0] a, logic [7:0] len, logic [1:0] burst);
        logic [31:0] mask;
        mask = {22'b0, len, 2'b11};                  // WRAP container bytes - 1
        case (burst)
            FIXED:   return a;
            WRAP:    return (a & ~mask) | ((a + 32'd4) & mask);
            default: return {a[31:2] + 30'd1, 2'b00};
        endcase
    endfunction

    function automatic logic [31:0] data_of(logic [31:0] a, logic [15:0] ep);
        return {ep, a[31:30], a[13:0]};
    endfunction

    // ---------------------------------------------------------------- LFSR
    logic [31:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= SEED;
        else        lfsr <= {1'b0, lfsr[31:1]} ^ (lfsr[0] ? 32'h8020_0003 : 32'h0);
    end

    logic gap_w, stall_b, stall_r;
    assign gap_w   = stall_en && (lfsr[24:23] == 2'b00);
    assign stall_b = stall_en && (lfsr[26:25] == 2'b00);
    assign stall_r = stall_en && (lfsr[28:27] == 2'b00);

    // ---------------------------------------------------------------- state
    typedef enum logic [2:0] {S_IDLE, S_GEN, S_WR, S_B, S_AR, S_R} state_t;
    state_t state;

    logic [ID_WIDTH-1:0] id_q;
    logic [31:0]         addr_q;
    logic [7:0]          len_q;
    logic [1:0]          burst_q;
    logic                unmapped_q;
    logic [15:0]         epoch;

    logic                awvalid_q, aw_sent;
    logic                wvalid_q, wlast_q, w_done;
    logic [31:0]         wdata_q, w_addr;
    logic [7:0]          w_cnt;
    logic                arvalid_q;
    logic [31:0]         r_addr;
    logic [7:0]          r_cnt;

    // Random transaction fields (evaluated in S_GEN)
    logic [1:0]  g_sel;
    logic [4:0]  g_blk;
    logic [3:0]  g_off;
    logic [1:0]  g_burst;
    logic [7:0]  g_len;
    logic [31:0] g_addr;

    always_comb begin
        logic [3:0] maxlen, rl;
        g_sel = (lfsr[1:0] == 2'd3) ? {1'b0, lfsr[2]} : lfsr[1:0];
        if (decerr_en && epoch[5:0] == 6'd63) g_sel = 2'd3;   // every 64th transaction
        g_blk = lfsr[8:4];
        g_off = lfsr[12:9];
        case (lfsr[14:13])
            2'd0:    g_burst = FIXED;
            2'd3:    g_burst = WRAP;
            default: g_burst = INCR;
        endcase
        maxlen = 4'd15 - g_off;
        rl     = lfsr[18:15];
        case (g_burst)
            FIXED:   g_len = {5'b0, lfsr[17:15]};
            WRAP:    case (lfsr[16:15])
                         2'd0: g_len = 8'd1;  2'd1: g_len = 8'd3;
                         2'd2: g_len = 8'd7;  default: g_len = 8'd15;
                     endcase
            default: g_len = {4'b0, (rl > maxlen) ? maxlen : rl};   // stay inside the 64 B block
        endcase
        g_addr = {g_sel, 18'b0, 1'(MIDX), g_blk, g_off, 2'b00};
    end

    // ---------------------------------------------------------------- AXI outputs
    assign m.awid    = id_q;
    assign m.awaddr  = addr_q;
    assign m.awlen   = len_q;
    assign m.awsize  = 3'd2;
    assign m.awburst = burst_q;
    assign m.awvalid = awvalid_q;
    assign m.wdata   = wdata_q;
    assign m.wstrb   = 4'hF;
    assign m.wlast   = wlast_q;
    assign m.wvalid  = wvalid_q;
    assign m.bready  = (state == S_B) && !stall_b;
    assign m.arid    = id_q;
    assign m.araddr  = addr_q;
    assign m.arlen   = len_q;
    assign m.arsize  = 3'd2;
    assign m.arburst = burst_q;
    assign m.arvalid = arvalid_q;
    assign m.rready  = (state == S_R) && !stall_r;

    logic w_hs, b_hs, r_hs;
    assign w_hs   = m.wvalid && m.wready;
    assign b_hs   = m.bvalid && m.bready;
    assign r_hs   = m.rvalid && m.rready;
    assign beat_w = w_hs;
    assign beat_r = r_hs;
    assign idle   = (state == S_IDLE);

    // ---------------------------------------------------------------- main FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            id_q <= '0; addr_q <= '0; len_q <= '0; burst_q <= INCR; unmapped_q <= 1'b0;
            epoch <= '0;
            awvalid_q <= 1'b0; aw_sent <= 1'b0;
            wvalid_q <= 1'b0; wlast_q <= 1'b0; w_done <= 1'b0; wdata_q <= '0; w_addr <= '0; w_cnt <= '0;
            arvalid_q <= 1'b0; r_addr <= '0; r_cnt <= '0;
            txn_count <= '0; aw_count <= '0; ar_count <= '0; decerr_count <= '0; err_count <= '0;
            err_data <= 1'b0; err_resp <= 1'b0; err_proto <= 1'b0;
        end else begin
            if (clear) begin
                txn_count <= '0; aw_count <= '0; ar_count <= '0; decerr_count <= '0; err_count <= '0;
                err_data <= 1'b0; err_resp <= 1'b0; err_proto <= 1'b0;
            end

            case (state)
                S_IDLE: if (run && !clear) state <= S_GEN;

                S_GEN: begin
                    id_q       <= lfsr[22:19];
                    addr_q     <= g_addr;
                    len_q      <= g_len;
                    burst_q    <= g_burst;
                    unmapped_q <= (g_sel == 2'd3);
                    awvalid_q  <= 1'b1;
                    aw_sent    <= 1'b0;
                    w_addr     <= g_addr;
                    w_cnt      <= '0;
                    w_done     <= 1'b0;
                    wvalid_q   <= 1'b1;                  // first W beat presented with AW
                    wdata_q    <= data_of(g_addr, epoch);
                    wlast_q    <= (g_len == 8'd0);
                    state      <= S_WR;
                end

                S_WR: begin
                    if (m.awvalid && m.awready) begin
                        awvalid_q <= 1'b0;
                        aw_sent   <= 1'b1;
                        aw_count  <= aw_count + 1;
                    end
                    if (w_hs) begin
                        if (wlast_q) begin
                            wvalid_q <= 1'b0;
                            wlast_q  <= 1'b0;
                            w_done   <= 1'b1;
                        end else begin
                            w_addr <= next_addr(w_addr, len_q, burst_q);
                            w_cnt  <= w_cnt + 8'd1;
                            if (gap_w) begin
                                wvalid_q <= 1'b0;
                            end else begin
                                wdata_q <= data_of(next_addr(w_addr, len_q, burst_q), epoch);
                                wlast_q <= (w_cnt + 8'd1 == len_q);
                            end
                        end
                    end else if (!wvalid_q && !w_done && !gap_w) begin
                        wvalid_q <= 1'b1;
                        wdata_q  <= data_of(w_addr, epoch);
                        wlast_q  <= (w_cnt == len_q);
                    end
                    if (aw_sent && w_done) state <= S_B;
                end

                S_B: if (b_hs) begin
                    if (m.bid != id_q) begin err_proto <= 1'b1; err_count <= err_count + 1; end
                    if (m.bresp != (unmapped_q ? DECERR : OKAY)) begin
                        err_resp <= 1'b1; err_count <= err_count + 1;
                    end
                    if (m.bresp == DECERR) decerr_count <= decerr_count + 1;
                    arvalid_q <= 1'b1;
                    state     <= S_AR;
                end

                S_AR: if (m.arvalid && m.arready) begin
                    arvalid_q <= 1'b0;
                    ar_count  <= ar_count + 1;
                    r_addr    <= addr_q;
                    r_cnt     <= '0;
                    state     <= S_R;
                end

                S_R: if (r_hs) begin
                    if (m.rid != id_q || m.rlast != (r_cnt == len_q)) begin
                        err_proto <= 1'b1; err_count <= err_count + 1;
                    end else if (m.rresp != (unmapped_q ? DECERR : OKAY)) begin
                        err_resp <= 1'b1; err_count <= err_count + 1;
                    end else if (!unmapped_q && m.rdata != data_of(r_addr, epoch)) begin
                        err_data <= 1'b1; err_count <= err_count + 1;
                    end
                    r_addr <= next_addr(r_addr, len_q, burst_q);
                    r_cnt  <= r_cnt + 8'd1;
                    if (m.rlast) begin
                        if (m.rresp == DECERR) decerr_count <= decerr_count + 1;
                        txn_count <= txn_count + 1;
                        epoch     <= epoch + 16'd1;
                        state     <= run ? S_GEN : S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
