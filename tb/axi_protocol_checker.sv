`timescale 1ns/1ps
// =============================================================================
// Passive AXI4 protocol checker (attach to any axi4_if instance)
// =============================================================================
// Rules checked every cycle (AMBA AXI IHI0022, section A3):
//   1. Once VALID is high it stays high until READY (all 5 channels)
//   2. Payload is stable while VALID is high and READY is low
//   3. WLAST occurs exactly on beat AWLEN+1 (W bursts matched to AWs in order)
//   4. A B response only follows a fully completed write, with the AW's ID
//   5. Every R beat belongs to an accepted AR, carries its ARID, and RLAST
//      occurs exactly on beat ARLEN+1
//   6. No VALID while in reset
// Sampling: falling edge (race-free; see BFM timing discipline).
// Also counts stall cycles (VALID && !READY) per channel for coverage.
// =============================================================================
module axi_protocol_checker
    import axi_tb_pkg::*;
#(
    parameter string NAME = "axi"
)(
    input logic clk,
    input logic rst_n,
    axi4_if     bus
);

    int errors = 0;

    // Coverage: stall cycles and handshakes per channel
    int aw_stalls = 0, w_stalls = 0, b_stalls = 0, ar_stalls = 0, r_stalls = 0;
    int aw_hs = 0, w_hs = 0, b_hs = 0, ar_hs = 0, r_hs = 0;

    // Previous-cycle sampled values
    logic p_awv, p_awr, p_wv, p_wr, p_bv, p_br, p_arv, p_arr, p_rv, p_rr;
    logic [TB_ID_W+TB_ADDR_W+8+3+2-1:0] p_aw, p_ar;
    logic [TB_DATA_W+TB_STRB_W+1-1:0]   p_w;
    logic [TB_ID_W+2-1:0]               p_b;
    logic [TB_ID_W+TB_DATA_W+2+1-1:0]   p_r;

    // Write bookkeeping
    int                 aw_len_q [$];   // AWLEN of accepted AWs waiting for W
    logic [TB_ID_W-1:0] aw_id_q  [$];   // IDs of writes waiting for B
    int                 w_done_q [$];   // beat counts of completed W bursts
    int                 w_beats  = 0;
    int                 writes_complete = 0;  // AW+W both finished, B owed

    // Read bookkeeping
    logic [TB_ID_W-1:0] ar_id_q  [$];
    int                 ar_len_q [$];
    int                 r_beats  = 0;

    function automatic void fail(string msg);
        $display("[%0t] ERROR [%s] %s", $time, NAME, msg);
        errors++;
    endfunction

    // Sampled on the falling edge: these are exactly the values the next
    // rising edge will register (TB drives 1 ns after the rising edge)
    // Note: no initialised declarations inside the always block — they would
    // be static and only evaluated once at time 0.
    int                 exp_beats, got_beats;
    logic [TB_ID_W-1:0] exp_id;

    always @(negedge clk) begin
        if (!rst_n) begin
            if (bus.awvalid || bus.wvalid || bus.bvalid || bus.arvalid || bus.rvalid)
                fail("VALID asserted during reset");
            p_awv <= 0; p_wv <= 0; p_bv <= 0; p_arv <= 0; p_rv <= 0;
        end else begin
            // ---------------- 1 & 2: VALID hold + payload stability ----------
            if (p_awv && !p_awr) begin
                if (!bus.awvalid) fail("AWVALID dropped before AWREADY");
                else if ({bus.awid, bus.awaddr, bus.awlen, bus.awsize, bus.awburst} != p_aw)
                    fail("AW payload changed while stalled");
            end
            if (p_wv && !p_wr) begin
                if (!bus.wvalid) fail("WVALID dropped before WREADY");
                else if ({bus.wdata, bus.wstrb, bus.wlast} != p_w)
                    fail("W payload changed while stalled");
            end
            if (p_bv && !p_br) begin
                if (!bus.bvalid) fail("BVALID dropped before BREADY");
                else if ({bus.bid, bus.bresp} != p_b)
                    fail("B payload changed while stalled");
            end
            if (p_arv && !p_arr) begin
                if (!bus.arvalid) fail("ARVALID dropped before ARREADY");
                else if ({bus.arid, bus.araddr, bus.arlen, bus.arsize, bus.arburst} != p_ar)
                    fail("AR payload changed while stalled");
            end
            if (p_rv && !p_rr) begin
                if (!bus.rvalid) fail("RVALID dropped before RREADY");
                else if ({bus.rid, bus.rdata, bus.rresp, bus.rlast} != p_r)
                    fail("R payload changed while stalled");
            end

            // ---------------- coverage --------------------------------------
            if (bus.awvalid && !bus.awready) aw_stalls++;
            if (bus.wvalid  && !bus.wready)  w_stalls++;
            if (bus.bvalid  && !bus.bready)  b_stalls++;
            if (bus.arvalid && !bus.arready) ar_stalls++;
            if (bus.rvalid  && !bus.rready)  r_stalls++;

            // ---------------- 3 & 4: write ordering ---------------------------
            if (bus.awvalid && bus.awready) begin
                aw_hs++;
                aw_len_q.push_back(int'(bus.awlen));
                aw_id_q.push_back(bus.awid);
            end
            if (bus.wvalid && bus.wready) begin
                w_hs++;
                w_beats++;
                if (bus.wlast) begin
                    w_done_q.push_back(w_beats);
                    w_beats = 0;
                end
            end
            // Match completed W bursts against AWs in order
            while (aw_len_q.size() > 0 && w_done_q.size() > 0) begin
                exp_beats = aw_len_q.pop_front() + 1;
                got_beats = w_done_q.pop_front();
                if (exp_beats != got_beats)
                    fail($sformatf("WLAST after %0d beats, AWLEN implies %0d", got_beats, exp_beats));
                writes_complete++;
            end
            if (bus.bvalid && bus.bready) begin
                b_hs++;
                if (writes_complete == 0 || aw_id_q.size() == 0)
                    fail("B response before write address and data completed");
                else begin
                    exp_id = aw_id_q.pop_front();
                    writes_complete--;
                    if (bus.bid != exp_id)
                        fail($sformatf("BID 0x%0h, expected 0x%0h", bus.bid, exp_id));
                end
            end

            // ---------------- 5: read ordering --------------------------------
            if (bus.arvalid && bus.arready) begin
                ar_hs++;
                ar_id_q.push_back(bus.arid);
                ar_len_q.push_back(int'(bus.arlen));
            end
            if (bus.rvalid && bus.rready) begin
                r_hs++;
                if (ar_id_q.size() == 0) begin
                    fail("R beat with no outstanding AR");
                end else begin
                    if (bus.rid != ar_id_q[0])
                        fail($sformatf("RID 0x%0h, expected 0x%0h", bus.rid, ar_id_q[0]));
                    if (bus.rlast !== (r_beats == ar_len_q[0]))
                        fail($sformatf("RLAST=%0b on beat %0d of %0d", bus.rlast, r_beats, ar_len_q[0] + 1));
                    if (bus.rlast) begin
                        void'(ar_id_q.pop_front());
                        void'(ar_len_q.pop_front());
                        r_beats = 0;
                    end else begin
                        r_beats++;
                    end
                end
            end

            // ---------------- sample for next cycle ---------------------------
            p_awv <= bus.awvalid; p_awr <= bus.awready;
            p_wv  <= bus.wvalid;  p_wr  <= bus.wready;
            p_bv  <= bus.bvalid;  p_br  <= bus.bready;
            p_arv <= bus.arvalid; p_arr <= bus.arready;
            p_rv  <= bus.rvalid;  p_rr  <= bus.rready;
            p_aw  <= {bus.awid, bus.awaddr, bus.awlen, bus.awsize, bus.awburst};
            p_w   <= {bus.wdata, bus.wstrb, bus.wlast};
            p_b   <= {bus.bid, bus.bresp};
            p_ar  <= {bus.arid, bus.araddr, bus.arlen, bus.arsize, bus.arburst};
            p_r   <= {bus.rid, bus.rdata, bus.rresp, bus.rlast};
        end
    end

    // Final consistency: nothing left dangling at end of test
    function automatic void final_check();
        if (aw_len_q.size() != 0 || w_done_q.size() != 0 || aw_id_q.size() != 0 || w_beats != 0)
            fail("write transactions left incomplete at end of test");
        if (ar_id_q.size() != 0 || r_beats != 0)
            fail("read transactions left incomplete at end of test");
    endfunction

endmodule
