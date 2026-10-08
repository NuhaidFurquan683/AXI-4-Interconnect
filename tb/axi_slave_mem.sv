`timescale 1ns/1ps
// =============================================================================
// AXI4 slave memory model
// =============================================================================
// - Byte-addressed sparse memory (associative array), honours WSTRB
// - Supports FIXED / INCR / WRAP bursts
// - Random backpressure: AWREADY / WREADY / ARREADY stalls, random B latency,
//   random idle cycles between R beats
// - Self-checks: every address it receives must decode to this slave index
//   (proves the crossbar routed it correctly), WLAST must match AWLEN
// Timing discipline: drive 1 ns after the rising edge, sample on falling edge.
// =============================================================================
module axi_slave_mem
    import axi_tb_pkg::*;
#(
    parameter int SIDX       = 0,
    parameter int NUM_SLAVES = 3
)(
    input logic   clk,
    input logic   rst_n,
    axi4_if.slave s
);

    localparam int SELW = $clog2(NUM_SLAVES);

    // Local drivers
    logic                 awready_d = 1'b0;
    logic                 wready_d  = 1'b0;
    logic [TB_ID_W-1:0]   bid_d     = '0;
    logic [1:0]           bresp_d   = '0;
    logic                 bvalid_d  = 1'b0;
    logic                 arready_d = 1'b0;
    logic [TB_ID_W-1:0]   rid_d     = '0;
    logic [TB_DATA_W-1:0] rdata_d   = '0;
    logic [1:0]           rresp_d   = '0;
    logic                 rlast_d   = 1'b0;
    logic                 rvalid_d  = 1'b0;

    assign s.awready = awready_d;  assign s.wready = wready_d;
    assign s.bid     = bid_d;      assign s.bresp  = bresp_d;   assign s.bvalid = bvalid_d;
    assign s.arready = arready_d;
    assign s.rid     = rid_d;      assign s.rdata  = rdata_d;   assign s.rresp  = rresp_d;
    assign s.rlast   = rlast_d;    assign s.rvalid = rvalid_d;

    // Stall knobs (percent), set by the test
    int aw_stall_pct = 0;
    int w_stall_pct  = 0;
    int ar_stall_pct = 0;
    int r_stall_pct  = 0;
    int b_delay_max  = 0;

    int errors    = 0;
    int writes_rx = 0;
    int reads_rx  = 0;

    logic [7:0] mem [logic [TB_ADDR_W-1:0]];

    function automatic bit roll(int pct);
        return ($urandom_range(0, 99) < pct);
    endfunction

    task automatic cyc();
        @(posedge clk);
        #1;
    endtask

    function automatic void fail(string msg);
        $display("[%0t] ERROR [SLAVE%0d] %s", $time, SIDX, msg);
        errors++;
    endfunction

    function automatic logic [TB_DATA_W-1:0] rd_word(logic [TB_ADDR_W-1:0] a);
        logic [TB_DATA_W-1:0] d = '0;
        logic [TB_ADDR_W-1:0] base = {a[TB_ADDR_W-1:2], 2'b00};
        for (int b = 0; b < TB_STRB_W; b++)
            if (mem.exists(base + TB_ADDR_W'(b))) d[8*b +: 8] = mem[base + TB_ADDR_W'(b)];
        return d;
    endfunction

    function automatic void check_route(logic [TB_ADDR_W-1:0] a, string ch);
        if (int'(a[TB_ADDR_W-1 -: SELW]) != SIDX)
            fail($sformatf("%s address 0x%08h routed to wrong slave", ch, a));
    endfunction

    // ---------------------------------------------------------------- write side
    initial begin : write_side
        logic [TB_ID_W-1:0]   id;
        logic [TB_ADDR_W-1:0] addr, a;
        logic [7:0]           len;
        logic [2:0]           size;
        logic [1:0]           burst;
        int                   beat;
        bit                   hs, last;

        @(posedge rst_n);
        cyc();
        forever begin
            // ---- AW ----
            forever begin
                awready_d = !roll(aw_stall_pct);
                @(negedge clk);
                hs = s.awvalid && awready_d;
                if (hs) begin
                    id = s.awid; addr = s.awaddr; len = s.awlen; size = s.awsize; burst = s.awburst;
                end
                cyc();
                if (hs) break;
            end
            awready_d = 1'b0;
            check_route(addr, "AW");
            writes_rx++;

            // ---- W ----
            beat = 0;
            forever begin
                wready_d = !roll(w_stall_pct);
                @(negedge clk);
                last = 0;
                if (s.wvalid && wready_d) begin
                    a = beat_addr(addr, size, len, burst, beat);
                    for (int b = 0; b < TB_STRB_W; b++)
                        if (s.wstrb[b])
                            mem[{a[TB_ADDR_W-1:2], 2'b00} + TB_ADDR_W'(b)] = s.wdata[8*b +: 8];
                    if (s.wlast != (beat == int'(len)))
                        fail($sformatf("WLAST=%0b on beat %0d of %0d", s.wlast, beat, len + 1));
                    last = s.wlast;
                    beat++;
                end
                cyc();
                if (last) break;
            end
            wready_d = 1'b0;

            // ---- B ----
            repeat ($urandom_range(0, b_delay_max)) cyc();
            bid_d    = id;
            bresp_d  = RESP_OKAY;
            bvalid_d = 1'b1;
            do @(negedge clk); while (!s.bready);
            cyc();
            bvalid_d = 1'b0;
        end
    end

    // ---------------------------------------------------------------- read side
    initial begin : read_side
        logic [TB_ID_W-1:0]   id;
        logic [TB_ADDR_W-1:0] addr;
        logic [7:0]           len;
        logic [2:0]           size;
        logic [1:0]           burst;
        bit                   hs;

        @(posedge rst_n);
        cyc();
        forever begin
            forever begin
                arready_d = !roll(ar_stall_pct);
                @(negedge clk);
                hs = s.arvalid && arready_d;
                if (hs) begin
                    id = s.arid; addr = s.araddr; len = s.arlen; size = s.arsize; burst = s.arburst;
                end
                cyc();
                if (hs) break;
            end
            arready_d = 1'b0;
            check_route(addr, "AR");
            reads_rx++;

            for (int i = 0; i <= int'(len); i++) begin
                if (roll(r_stall_pct)) begin
                    rvalid_d = 1'b0;
                    repeat ($urandom_range(1, 3)) cyc();
                end
                rid_d    = id;
                rdata_d  = rd_word(beat_addr(addr, size, len, burst, i));
                rresp_d  = RESP_OKAY;
                rlast_d  = (i == int'(len));
                rvalid_d = 1'b1;
                do @(negedge clk); while (!s.rready);
                cyc();
            end
            rvalid_d = 1'b0;
            rlast_d  = 1'b0;
        end
    end

endmodule
