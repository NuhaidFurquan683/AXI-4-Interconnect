// =============================================================================
// Top-level self-checking testbench: AXI4 2x3 crossbar + AXI4-Lite control
// =============================================================================
// Test plan
//   T1  basic      every master -> every slave, single-beat write + readback
//   T2  burst      INCR (1..256 beats), WRAP (2/4/8/16), FIXED, random WSTRB
//   T3  contention both masters hammer one slave: completion + round-robin
//                  fairness (strict alternation) on writes and reads
//   T4  parallel   disjoint master/slave pairs transfer in the same cycles;
//                  read and write to the same slave overlap
//   T5  decerr     unmapped address -> DECERR on B and on every R beat,
//                  no slave sees the access, normal traffic still works
//   T6  stall      heavy random backpressure on every channel, both sides
//   T7  random     mixed concurrent read/write traffic, all burst types,
//                  scoreboard readback of every written location
//   T8  control    AXI4-Lite counters match observed traffic, CLEAR,
//                  COUNT_EN, SCRATCH with byte strobes, SLVERR decode
//
// Checking
//   - Golden byte-memory scoreboard for all read data
//   - Response ID / RESP / beat count checks on every transaction
//   - axi_protocol_checker on every master and slave port
//   - Slave models flag any address routed to the wrong slave
// =============================================================================
`timescale 1ns/1ps

module tb_axi4_crossbar;
    import axi_tb_pkg::*;

    parameter bit REG_SLICE = 1'b1;

    localparam int NM = 2;
    localparam int NS = 3;

    // ------------------------------------------------------------------ clock
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    // ------------------------------------------------------------------ DUT
    axi4_if #(.ADDR_WIDTH(TB_ADDR_W), .DATA_WIDTH(TB_DATA_W), .ID_WIDTH(TB_ID_W)) mif [NM] ();
    axi4_if #(.ADDR_WIDTH(TB_ADDR_W), .DATA_WIDTH(TB_DATA_W), .ID_WIDTH(TB_ID_W)) sif [NS] ();
    axi4_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cif ();

    logic [NM-1:0] st_aw, st_ar, st_awe, st_are;

    axi4_crossbar #(
        .NUM_MASTERS (NM),
        .NUM_SLAVES  (NS),
        .ADDR_WIDTH  (TB_ADDR_W),
        .DATA_WIDTH  (TB_DATA_W),
        .ID_WIDTH    (TB_ID_W),
        .REG_SLICE   (REG_SLICE)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .master_ports      (mif),
        .slave_ports       (sif),
        .stat_aw_handshake (st_aw),
        .stat_ar_handshake (st_ar),
        .stat_aw_decerr    (st_awe),
        .stat_ar_decerr    (st_are)
    );

    axi4_lite_control #(.NUM_MASTERS(NM), .NUM_SLAVES(NS)) u_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .ctrl_port    (cif),
        .aw_handshake (st_aw),
        .ar_handshake (st_ar),
        .aw_decerr    (st_awe),
        .ar_decerr    (st_are)
    );

    // ------------------------------------------------------------------ BFMs
    axi_master_bfm #(.MIDX(0)) u_m0 (.clk(clk), .rst_n(rst_n), .m(mif[0]));
    axi_master_bfm #(.MIDX(1)) u_m1 (.clk(clk), .rst_n(rst_n), .m(mif[1]));

    axi_slave_mem #(.SIDX(0), .NUM_SLAVES(NS)) u_s0 (.clk(clk), .rst_n(rst_n), .s(sif[0]));
    axi_slave_mem #(.SIDX(1), .NUM_SLAVES(NS)) u_s1 (.clk(clk), .rst_n(rst_n), .s(sif[1]));
    axi_slave_mem #(.SIDX(2), .NUM_SLAVES(NS)) u_s2 (.clk(clk), .rst_n(rst_n), .s(sif[2]));

    axil_master_bfm u_cm (.clk(clk), .rst_n(rst_n), .m(cif));

    // ------------------------------------------------------------------ checkers
    axi_protocol_checker #(.NAME("M0")) u_chk_m0 (.clk(clk), .rst_n(rst_n), .bus(mif[0]));
    axi_protocol_checker #(.NAME("M1")) u_chk_m1 (.clk(clk), .rst_n(rst_n), .bus(mif[1]));
    axi_protocol_checker #(.NAME("S0")) u_chk_s0 (.clk(clk), .rst_n(rst_n), .bus(sif[0]));
    axi_protocol_checker #(.NAME("S1")) u_chk_s1 (.clk(clk), .rst_n(rst_n), .bus(sif[1]));
    axi_protocol_checker #(.NAME("S2")) u_chk_s2 (.clk(clk), .rst_n(rst_n), .bus(sif[2]));

    // ------------------------------------------------------------------ scoreboard
    logic [7:0] gold [logic [TB_ADDR_W-1:0]];
    int tb_errors = 0;
    int tests_run = 0;
    int txns_checked = 0;
    int decerr_issued [NM];

    function automatic void fail(string msg);
        $display("[%0t] ERROR [TB] %s", $time, msg);
        tb_errors++;
    endfunction

    function automatic logic [TB_ADDR_W-1:0] mk_addr(int slv, int mst, int region, int off);
        return (TB_ADDR_W'(slv) << 30) | (TB_ADDR_W'(mst) << 24) |
               (TB_ADDR_W'(region) << 20) | TB_ADDR_W'(off & 32'hFFFF);
    endfunction

    function automatic void gold_apply(axi_txn t);
        for (int i = 0; i <= int'(t.len); i++) begin
            logic [TB_ADDR_W-1:0] a = beat_addr(t.addr, t.size, t.len, t.burst, i);
            for (int b = 0; b < TB_STRB_W; b++)
                if (t.wstrb[i][b]) gold[{a[TB_ADDR_W-1:2], 2'b00} + TB_ADDR_W'(b)] = t.wdata[i][8*b +: 8];
        end
    endfunction

    function automatic logic [TB_DATA_W-1:0] gold_word(logic [TB_ADDR_W-1:0] a);
        logic [TB_DATA_W-1:0] d = '0;
        logic [TB_ADDR_W-1:0] base = {a[TB_ADDR_W-1:2], 2'b00};
        for (int b = 0; b < TB_STRB_W; b++)
            if (gold.exists(base + TB_ADDR_W'(b))) d[8*b +: 8] = gold[base + TB_ADDR_W'(b)];
        return d;
    endfunction

    function automatic axi_txn new_txn(bit wr, logic [TB_ADDR_W-1:0] addr, int len,
                                       logic [1:0] burst, bit rand_strb);
        axi_txn t = new();
        t.is_write = wr;
        t.id       = TB_ID_W'($urandom);
        t.addr     = addr;
        t.len      = 8'(len);
        t.burst    = burst;
        if (wr) begin
            for (int i = 0; i <= len; i++) begin
                t.wdata.push_back($urandom);
                t.wstrb.push_back(rand_strb ? TB_STRB_W'($urandom) : '1);
            end
        end
        return t;
    endfunction

    // Copy of a write's address phase as a read (for readback)
    function automatic axi_txn as_read(axi_txn w);
        axi_txn r = new_txn(0, w.addr, int'(w.len), w.burst, 0);
        return r;
    endfunction

    // Random legal transaction for master mst to slave slv in a region
    function automatic axi_txn rand_txn(bit wr, int mst, int slv, int region);
        int sel = $urandom_range(0, 9);
        int len, off;
        logic [1:0] burst;
        if (sel < 6) begin
            burst = BURST_INCR;
            len   = ($urandom_range(0, 9) == 0) ? $urandom_range(16, 63) : $urandom_range(0, 15);
        end else if (sel < 8) begin
            int wl[4] = '{1, 3, 7, 15};
            burst = BURST_WRAP;
            len   = wl[$urandom_range(0, 3)];
        end else begin
            burst = BURST_FIXED;
            len   = $urandom_range(0, 7);
        end
        off = $urandom_range(0, 16383) * 4;
        if (burst == BURST_INCR && ((off & 4095) + (len + 1) * 4 > 4096))
            off = off & ~4095;                       // never cross a 4KB boundary
        return new_txn(wr, mk_addr(slv, mst, region, off), len, burst, 1);
    endfunction

    task automatic issue(int mst, axi_txn t);
        if (mst == 0) u_m0.push(t);
        else          u_m1.push(t);
    endtask

    task automatic wait_txn(axi_txn t);
        while (!t.done) @(posedge clk);
    endtask

    function automatic void check_write(axi_txn t, logic [1:0] exp_resp);
        txns_checked++;
        if (t.rsp_id != t.id)
            fail($sformatf("write @0x%08h: BID 0x%0h != AWID 0x%0h", t.addr, t.rsp_id, t.id));
        if (t.bresp != exp_resp)
            fail($sformatf("write @0x%08h: BRESP %0b, expected %0b", t.addr, t.bresp, exp_resp));
    endfunction

    function automatic void check_read(axi_txn t, logic [1:0] exp_resp);
        txns_checked++;
        if (t.rsp_id != t.id)
            fail($sformatf("read @0x%08h: RID 0x%0h != ARID 0x%0h", t.addr, t.rsp_id, t.id));
        if (t.rdata.size() != int'(t.len) + 1) begin
            fail($sformatf("read @0x%08h: %0d beats, expected %0d", t.addr, t.rdata.size(), t.len + 1));
            return;
        end
        for (int i = 0; i <= int'(t.len); i++) begin
            logic [TB_DATA_W-1:0] exp;
            if (t.rresp[i] != exp_resp)
                fail($sformatf("read @0x%08h beat %0d: RRESP %0b, expected %0b", t.addr, i, t.rresp[i], exp_resp));
            if (exp_resp == RESP_OKAY) begin
                exp = gold_word(beat_addr(t.addr, t.size, t.len, t.burst, i));
                if (t.rdata[i] != exp)
                    fail($sformatf("read @0x%08h beat %0d: data 0x%08h, expected 0x%08h",
                                   t.addr, i, t.rdata[i], exp));
            end
        end
    endfunction

    // Blocking write / read with full checking
    task automatic do_write(int mst, axi_txn t);
        issue(mst, t);
        wait_txn(t);
        check_write(t, RESP_OKAY);
        gold_apply(t);
    endtask

    task automatic do_read(int mst, axi_txn t);
        issue(mst, t);
        wait_txn(t);
        check_read(t, RESP_OKAY);
    endtask

    task automatic set_stalls(int pct, int bdelay);
        u_s0.aw_stall_pct = pct; u_s0.w_stall_pct = pct; u_s0.ar_stall_pct = pct;
        u_s0.r_stall_pct  = pct; u_s0.b_delay_max = bdelay;
        u_s1.aw_stall_pct = pct; u_s1.w_stall_pct = pct; u_s1.ar_stall_pct = pct;
        u_s1.r_stall_pct  = pct; u_s1.b_delay_max = bdelay;
        u_s2.aw_stall_pct = pct; u_s2.w_stall_pct = pct; u_s2.ar_stall_pct = pct;
        u_s2.r_stall_pct  = pct; u_s2.b_delay_max = bdelay;
        u_m0.w_stall_pct = pct; u_m0.b_stall_pct = pct; u_m0.r_stall_pct = pct;
        u_m1.w_stall_pct = pct; u_m1.b_stall_pct = pct; u_m1.r_stall_pct = pct;
    endtask

    task automatic set_gaps(int g);
        u_m0.issue_gap_max = g;
        u_m1.issue_gap_max = g;
    endtask

    task automatic wait_idle();
        while (!(u_m0.idle() && u_m1.idle())) @(posedge clk);
        repeat (5) @(posedge clk);
    endtask

    task automatic banner(string name);
        tests_run++;
        $display("[%0t] ---- %s ----", $time, name);
    endtask

    // ------------------------------------------------------------------ monitors
    // Arbitration order at slave 1 (bit 24 of the address = issuing master)
    int s1_aw_order [$];
    int s1_ar_order [$];
    int par_w_cycles  = 0;   // cycles with W beats on slave 0 and slave 2 together
    int ovl_rw_cycles = 0;   // cycles with W beat and R beat on slave 1 together
    always @(negedge clk) begin
        if (sif[1].awvalid && sif[1].awready) s1_aw_order.push_back(int'(sif[1].awaddr[24]));
        if (sif[1].arvalid && sif[1].arready) s1_ar_order.push_back(int'(sif[1].araddr[24]));
        if (sif[0].wvalid && sif[0].wready && sif[2].wvalid && sif[2].wready) par_w_cycles++;
        if (sif[1].wvalid && sif[1].wready && sif[1].rvalid && sif[1].rready) ovl_rw_cycles++;
    end

    // =====================================================================
    //  T1: basic connectivity
    // =====================================================================
    task automatic t_basic();
        banner("T1 basic connectivity (each master -> each slave)");
        for (int m = 0; m < NM; m++)
            for (int s = 0; s < NS; s++) begin
                axi_txn w = new_txn(1, mk_addr(s, m, 0, 16'h0100), 0, BURST_INCR, 0);
                axi_txn r;
                do_write(m, w);
                r = as_read(w);
                do_read(m, r);
            end
    endtask

    // =====================================================================
    //  T2: bursts
    // =====================================================================
    task automatic t_burst();
        int incr_lens[7] = '{0, 1, 3, 7, 15, 63, 255};
        int wrap_lens[4] = '{1, 3, 7, 15};
        banner("T2 bursts: INCR / WRAP / FIXED with random strobes");
        for (int m = 0; m < NM; m++) begin
            int s = m + 1;
            // INCR, including the maximum 256-beat burst (page-aligned start)
            foreach (incr_lens[i]) begin
                axi_txn w = new_txn(1, mk_addr(s, m, 0, 16'h1000 * (i + 1)), incr_lens[i], BURST_INCR, 1);
                do_write(m, w);
                do_read(m, as_read(w));
            end
            // WRAP: start in the middle of the wrap container so it wraps
            foreach (wrap_lens[i]) begin
                int cont = (wrap_lens[i] + 1) * 4;
                axi_txn w = new_txn(1, mk_addr(s, m, 0, 16'h9000 + 16'h100 * i + cont / 2),
                                    wrap_lens[i], BURST_WRAP, 1);
                axi_txn chk;
                do_write(m, w);
                do_read(m, as_read(w));
                // Cross-check the wrap with an aligned INCR read of the container
                chk = new_txn(0, (w.addr / cont) * cont, wrap_lens[i], BURST_INCR, 0);
                do_read(m, chk);
            end
            // FIXED: all beats hit one word; final value = strobe-merged beats
            for (int len = 0; len < 8; len += 3) begin
                axi_txn w = new_txn(1, mk_addr(s, m, 0, 16'hA000 + 16'h10 * len), len, BURST_FIXED, 1);
                do_write(m, w);
                do_read(m, as_read(w));
            end
        end
    endtask

    // =====================================================================
    //  T3: contention on a single slave + fairness
    // =====================================================================
    task automatic t_contention();
        localparam int N = 16;
        axi_txn w0 [N], w1 [N], r0 [N], r1 [N];
        int streak, max_streak;
        banner("T3 contention: both masters -> slave 1, round-robin fairness");
        set_gaps(0);
        s1_aw_order.delete();
        s1_ar_order.delete();
        for (int i = 0; i < N; i++) begin
            w0[i] = new_txn(1, mk_addr(1, 0, 0, 16'hC000 + 64 * i), 3, BURST_INCR, 1);
            w1[i] = new_txn(1, mk_addr(1, 1, 0, 16'hC000 + 64 * i), 3, BURST_INCR, 1);
            issue(0, w0[i]);
            issue(1, w1[i]);
        end
        wait_idle();
        for (int i = 0; i < N; i++) begin
            check_write(w0[i], RESP_OKAY); gold_apply(w0[i]);
            check_write(w1[i], RESP_OKAY); gold_apply(w1[i]);
        end
        for (int i = 0; i < N; i++) begin
            r0[i] = as_read(w0[i]); issue(0, r0[i]);
            r1[i] = as_read(w1[i]); issue(1, r1[i]);
        end
        wait_idle();
        for (int i = 0; i < N; i++) begin
            check_read(r0[i], RESP_OKAY);
            check_read(r1[i], RESP_OKAY);
        end

        // Fairness: with both masters continuously requesting, grants alternate
        max_streak = 0; streak = 0;
        for (int i = 1; i < s1_aw_order.size(); i++) begin
            streak = (s1_aw_order[i] == s1_aw_order[i-1]) ? streak + 1 : 0;
            if (streak > max_streak) max_streak = streak;
        end
        if (s1_aw_order.size() != 2 * N) fail($sformatf("slave1 saw %0d AWs, expected %0d", s1_aw_order.size(), 2 * N));
        if (max_streak != 0) fail($sformatf("write arbitration not alternating (streak %0d)", max_streak + 1));
        max_streak = 0; streak = 0;
        for (int i = 1; i < s1_ar_order.size(); i++) begin
            streak = (s1_ar_order[i] == s1_ar_order[i-1]) ? streak + 1 : 0;
            if (streak > max_streak) max_streak = streak;
        end
        if (s1_ar_order.size() != 2 * N) fail($sformatf("slave1 saw %0d ARs, expected %0d", s1_ar_order.size(), 2 * N));
        if (max_streak != 0) fail($sformatf("read arbitration not alternating (streak %0d)", max_streak + 1));
        $display("        slave1 grant order (W): %p", s1_aw_order);
    endtask

    // =====================================================================
    //  T4: parallel transfers through the crossbar
    // =====================================================================
    task automatic t_parallel();
        axi_txn a, b, c, d;
        banner("T4 parallel: M0->S0 and M1->S2 concurrently; R+W overlap on S1");
        set_gaps(0);
        par_w_cycles = 0;
        a = new_txn(1, mk_addr(0, 0, 0, 16'hD000), 31, BURST_INCR, 0);
        b = new_txn(1, mk_addr(2, 1, 0, 16'hD000), 31, BURST_INCR, 0);
        issue(0, a); issue(1, b);
        wait_idle();
        check_write(a, RESP_OKAY); gold_apply(a);
        check_write(b, RESP_OKAY); gold_apply(b);
        if (par_w_cycles < 16)
            fail($sformatf("only %0d cycles of parallel W traffic (expected >= 16)", par_w_cycles));

        // M0 writes slave 1 while M1 reads slave 1 (independent channels)
        ovl_rw_cycles = 0;
        c = new_txn(1, mk_addr(1, 0, 0, 16'hE000), 31, BURST_INCR, 0);
        d = new_txn(0, mk_addr(1, 1, 0, 16'hC000), 31, BURST_INCR, 0);
        issue(0, c); issue(1, d);
        wait_idle();
        check_write(c, RESP_OKAY); gold_apply(c);
        check_read(d, RESP_OKAY);
        if (ovl_rw_cycles < 8)
            fail($sformatf("only %0d cycles of overlapping R/W on slave 1", ovl_rw_cycles));
        $display("        parallel W cycles: %0d, overlapping R/W cycles: %0d", par_w_cycles, ovl_rw_cycles);
    endtask

    // =====================================================================
    //  T5: decode error
    // =====================================================================
    task automatic t_decerr();
        int wr_before, rd_before;
        axi_txn w, r, ok;
        banner("T5 decode error: unmapped region returns DECERR");
        wr_before = u_s0.writes_rx + u_s1.writes_rx + u_s2.writes_rx;
        rd_before = u_s0.reads_rx  + u_s1.reads_rx  + u_s2.reads_rx;
        for (int m = 0; m < NM; m++) begin
            w = new_txn(1, 32'hC000_0000 + 32'h100 * m, 3, BURST_INCR, 0);
            issue(m, w); wait_txn(w);
            check_write(w, RESP_DECERR);
            r = new_txn(0, 32'hF000_0040, 5, BURST_INCR, 0);
            issue(m, r); wait_txn(r);
            check_read(r, RESP_DECERR);
            decerr_issued[m] += 2;
        end
        if (u_s0.writes_rx + u_s1.writes_rx + u_s2.writes_rx != wr_before ||
            u_s0.reads_rx  + u_s1.reads_rx  + u_s2.reads_rx  != rd_before)
            fail("a slave received a transaction to an unmapped address");
        // Crossbar must still work normally afterwards
        ok = new_txn(1, mk_addr(2, 0, 0, 16'h0200), 1, BURST_INCR, 0);
        do_write(0, ok);
        do_read(0, as_read(ok));
    endtask

    // =====================================================================
    //  T6 / T7: random traffic (with stall level as a parameter)
    // =====================================================================
    task automatic t_random(string name, int n_per_master, int stall_pct, int bdelay);
        axi_txn wl [NM][$];
        axi_txn rl [NM][$];
        axi_txn rb [$];
        banner(name);
        set_stalls(stall_pct, bdelay);
        set_gaps(2);
        // Writes go to region 1, reads come from region 0 (stable during the run)
        for (int i = 0; i < n_per_master; i++) begin
            for (int m = 0; m < NM; m++) begin
                if ($urandom_range(0, 1)) begin
                    axi_txn w = rand_txn(1, m, $urandom_range(0, NS - 1), 1);
                    wl[m].push_back(w); issue(m, w);
                end else begin
                    axi_txn r = rand_txn(0, m, $urandom_range(0, NS - 1), 0);
                    rl[m].push_back(r); issue(m, r);
                end
            end
        end
        wait_idle();
        for (int m = 0; m < NM; m++) begin
            foreach (wl[m][i]) begin check_write(wl[m][i], RESP_OKAY); gold_apply(wl[m][i]); end
            foreach (rl[m][i]) check_read(rl[m][i], RESP_OKAY);
        end
        // Scoreboard readback of every written location
        for (int m = 0; m < NM; m++)
            foreach (wl[m][i]) begin
                axi_txn r = as_read(wl[m][i]);
                rb.push_back(r); issue(m, r);
            end
        wait_idle();
        foreach (rb[i]) check_read(rb[i], RESP_OKAY);
        set_stalls(0, 0);
    endtask

    // =====================================================================
    //  T8: AXI4-Lite control plane
    // =====================================================================
    task automatic lite_expect(logic [31:0] addr, logic [31:0] exp, logic [1:0] exp_resp, string what);
        logic [31:0] d; logic [1:0] r;
        u_cm.read(addr, d, r);
        if (r != exp_resp) fail($sformatf("AXIL %s: RRESP %0b, expected %0b", what, r, exp_resp));
        else if (exp_resp == RESP_OKAY && d != exp)
            fail($sformatf("AXIL %s: read 0x%08h, expected 0x%08h", what, d, exp));
    endtask

    task automatic t_control();
        logic [1:0] resp;
        int aw_exp [NM], ar_exp [NM];
        axi_txn w;
        banner("T8 control plane: counters, CLEAR, COUNT_EN, SCRATCH, SLVERR");
        aw_exp[0] = u_chk_m0.aw_hs; ar_exp[0] = u_chk_m0.ar_hs;
        aw_exp[1] = u_chk_m1.aw_hs; ar_exp[1] = u_chk_m1.ar_hs;

        lite_expect(32'h00, 32'h0001_0000, RESP_OKAY, "VERSION");
        lite_expect(32'h04, {16'(NS), 16'(NM)}, RESP_OKAY, "CONFIG");
        lite_expect(32'h08, 32'h1, RESP_OKAY, "CONTROL reset value");
        for (int m = 0; m < NM; m++) begin
            lite_expect(32'h40 + 4 * m, aw_exp[m], RESP_OKAY, $sformatf("AW_COUNT[%0d]", m));
            lite_expect(32'h60 + 4 * m, ar_exp[m], RESP_OKAY, $sformatf("AR_COUNT[%0d]", m));
            lite_expect(32'h80 + 4 * m, decerr_issued[m], RESP_OKAY, $sformatf("ERR_COUNT[%0d]", m));
        end
        $display("        counters: M0 aw=%0d ar=%0d  M1 aw=%0d ar=%0d", aw_exp[0], ar_exp[0], aw_exp[1], ar_exp[1]);

        // SCRATCH with byte strobes
        u_cm.write(32'h0C, 32'hDEAD_BEEF, 4'hF, resp);
        if (resp != RESP_OKAY) fail("SCRATCH write not OKAY");
        u_cm.write(32'h0C, 32'h1122_3344, 4'b0101, resp);
        lite_expect(32'h0C, 32'hDE22_BE44, RESP_OKAY, "SCRATCH after strobed write");

        // Error responses
        u_cm.write(32'h00, 32'h0, 4'hF, resp);
        if (resp != RESP_SLVERR) fail("write to RO VERSION did not return SLVERR");
        lite_expect(32'h10, 0, RESP_SLVERR, "unmapped 0x10");
        lite_expect(32'h48 + 4 * NM, 0, RESP_SLVERR, "counter index beyond NUM_MASTERS");
        lite_expect(32'h02, 0, RESP_SLVERR, "unaligned 0x02");

        // CLEAR
        u_cm.write(32'h08, 32'h3, 4'hF, resp);            // COUNT_EN=1, CLEAR=1
        lite_expect(32'h40, 0, RESP_OKAY, "AW_COUNT[0] after CLEAR");
        lite_expect(32'h60, 0, RESP_OKAY, "AR_COUNT[0] after CLEAR");
        lite_expect(32'h80, 0, RESP_OKAY, "ERR_COUNT[0] after CLEAR");

        // Counting resumes
        w = new_txn(1, mk_addr(0, 0, 0, 16'h0300), 0, BURST_INCR, 0);
        do_write(0, w);
        do_read(0, as_read(w));
        lite_expect(32'h40, 1, RESP_OKAY, "AW_COUNT[0] after 1 write");
        lite_expect(32'h60, 1, RESP_OKAY, "AR_COUNT[0] after 1 read");

        // COUNT_EN = 0 freezes counters
        u_cm.write(32'h08, 32'h0, 4'hF, resp);
        do_write(0, new_txn(1, mk_addr(0, 0, 0, 16'h0304), 0, BURST_INCR, 0));
        lite_expect(32'h40, 1, RESP_OKAY, "AW_COUNT[0] with COUNT_EN=0");
        u_cm.write(32'h08, 32'h1, 4'hF, resp);
    endtask

    // =====================================================================
    //  Main sequence
    // =====================================================================
    initial begin
        int total_errors;
        decerr_issued[0] = 0;
        decerr_issued[1] = 0;
        $display("=== AXI4 crossbar testbench, REG_SLICE=%0d ===", REG_SLICE);
        repeat (10) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        t_basic();
        t_burst();
        t_contention();
        t_parallel();
        t_decerr();
        t_random("T6 stall: heavy backpressure on all channels", 150, 60, 8);
        t_random("T7 random: mixed concurrent traffic",          300, 20, 3);
        t_control();

        wait_idle();
        u_chk_m0.final_check(); u_chk_m1.final_check();
        u_chk_s0.final_check(); u_chk_s1.final_check(); u_chk_s2.final_check();

        total_errors = tb_errors + u_cm.errors
                     + u_chk_m0.errors + u_chk_m1.errors
                     + u_chk_s0.errors + u_chk_s1.errors + u_chk_s2.errors
                     + u_s0.errors + u_s1.errors + u_s2.errors;

        $display("");
        $display("=== Coverage ===");
        $display("  stall cycles  M0: aw=%0d w=%0d b=%0d ar=%0d r=%0d",
                 u_chk_m0.aw_stalls, u_chk_m0.w_stalls, u_chk_m0.b_stalls, u_chk_m0.ar_stalls, u_chk_m0.r_stalls);
        $display("  stall cycles  S1: aw=%0d w=%0d b=%0d ar=%0d r=%0d",
                 u_chk_s1.aw_stalls, u_chk_s1.w_stalls, u_chk_s1.b_stalls, u_chk_s1.ar_stalls, u_chk_s1.r_stalls);
        $display("  slave txns    S0: %0dW/%0dR  S1: %0dW/%0dR  S2: %0dW/%0dR",
                 u_s0.writes_rx, u_s0.reads_rx, u_s1.writes_rx, u_s1.reads_rx, u_s2.writes_rx, u_s2.reads_rx);
        $display("  W beats through crossbar: %0d, R beats: %0d",
                 u_chk_m0.w_hs + u_chk_m1.w_hs, u_chk_m0.r_hs + u_chk_m1.r_hs);
        $display("");
        if (total_errors == 0)
            $display("*** PASS: %0d tests, %0d transactions checked, 0 errors (REG_SLICE=%0d) ***",
                     tests_run, txns_checked, REG_SLICE);
        else
            $display("*** FAIL: %0d errors (REG_SLICE=%0d) ***", total_errors, REG_SLICE);
        $finish;
    end

    // Watchdog
    initial begin
        #20ms;
        $display("*** FAIL: watchdog timeout ***");
        $finish;
    end

endmodule
