`timescale 1ns/1ps
// =============================================================================
// AXI4 master bus-functional model
// =============================================================================
// - push(txn) queues a read or write; independent write and read engines
// - AW and W are driven concurrently (W may be presented before AW is accepted)
// - Random stall injection: idle cycles between W beats, BREADY / RREADY
//   deasserted randomly, random gaps between transactions
// - VALID and payload are held stable until the handshake (AXI rule)
//
// Timing discipline (race-free with any simulator):
//   drive  : 1 ns after the rising edge
//   sample : on the falling edge (the values the next rising edge will see)
// =============================================================================
module axi_master_bfm
    import axi_tb_pkg::*;
#(
    parameter int MIDX = 0
)(
    input logic    clk,
    input logic    rst_n,
    axi4_if.master m
);

    // Local drivers (interface signals are driven by continuous assigns)
    logic [TB_ID_W-1:0]   awid_d    = '0;
    logic [TB_ADDR_W-1:0] awaddr_d  = '0;
    logic [7:0]           awlen_d   = '0;
    logic [2:0]           awsize_d  = '0;
    logic [1:0]           awburst_d = '0;
    logic                 awvalid_d = 1'b0;
    logic [TB_DATA_W-1:0] wdata_d   = '0;
    logic [TB_STRB_W-1:0] wstrb_d   = '0;
    logic                 wlast_d   = 1'b0;
    logic                 wvalid_d  = 1'b0;
    logic                 bready_d  = 1'b0;
    logic [TB_ID_W-1:0]   arid_d    = '0;
    logic [TB_ADDR_W-1:0] araddr_d  = '0;
    logic [7:0]           arlen_d   = '0;
    logic [2:0]           arsize_d  = '0;
    logic [1:0]           arburst_d = '0;
    logic                 arvalid_d = 1'b0;
    logic                 rready_d  = 1'b0;

    assign m.awid    = awid_d;    assign m.awaddr  = awaddr_d;  assign m.awlen   = awlen_d;
    assign m.awsize  = awsize_d;  assign m.awburst = awburst_d; assign m.awvalid = awvalid_d;
    assign m.wdata   = wdata_d;   assign m.wstrb   = wstrb_d;   assign m.wlast   = wlast_d;
    assign m.wvalid  = wvalid_d;  assign m.bready  = bready_d;
    assign m.arid    = arid_d;    assign m.araddr  = araddr_d;  assign m.arlen   = arlen_d;
    assign m.arsize  = arsize_d;  assign m.arburst = arburst_d; assign m.arvalid = arvalid_d;
    assign m.rready  = rready_d;

    // Stall knobs (percent), set by the test
    int w_stall_pct   = 0;
    int b_stall_pct   = 0;
    int r_stall_pct   = 0;
    int issue_gap_max = 0;

    axi_txn wq [$];
    axi_txn rq [$];
    int     writes_done = 0;
    int     reads_done  = 0;
    bit     wr_active   = 0;
    bit     rd_active   = 0;

    function automatic void push(axi_txn t);
        if (t.is_write) wq.push_back(t);
        else            rq.push_back(t);
    endfunction

    function automatic bit idle();
        return (wq.size() == 0) && (rq.size() == 0) && !wr_active && !rd_active;
    endfunction

    function automatic bit roll(int pct);
        return ($urandom_range(0, 99) < pct);
    endfunction

    // Advance to the next drive point (1 ns after the rising edge)
    task automatic cyc();
        @(posedge clk);
        #1;
    endtask

    // ---------------------------------------------------------------- AW
    task automatic drive_aw(axi_txn t);
        awid_d   = t.id;   awaddr_d  = t.addr;  awlen_d = t.len;
        awsize_d = t.size; awburst_d = t.burst;
        awvalid_d = 1'b1;
        do @(negedge clk); while (!m.awready);
        cyc();
        awvalid_d = 1'b0;
    endtask

    // ---------------------------------------------------------------- W
    task automatic drive_w(axi_txn t);
        for (int i = 0; i <= int'(t.len); i++) begin
            if (roll(w_stall_pct)) begin
                wvalid_d = 1'b0;
                repeat ($urandom_range(1, 3)) cyc();
            end
            wdata_d  = t.wdata[i];
            wstrb_d  = t.wstrb[i];
            wlast_d  = (i == int'(t.len));
            wvalid_d = 1'b1;
            do @(negedge clk); while (!m.wready);
            cyc();
        end
        wvalid_d = 1'b0;
        wlast_d  = 1'b0;
    endtask

    // ---------------------------------------------------------------- B
    task automatic collect_b(axi_txn t);
        bit got;
        forever begin
            bready_d = !roll(b_stall_pct);
            @(negedge clk);
            got = m.bvalid && bready_d;
            if (got) begin
                t.rsp_id = m.bid;
                t.bresp  = m.bresp;
            end
            cyc();
            if (got) break;
        end
        bready_d = 1'b0;
    endtask

    // ---------------------------------------------------------------- AR
    task automatic drive_ar(axi_txn t);
        arid_d   = t.id;   araddr_d  = t.addr;  arlen_d = t.len;
        arsize_d = t.size; arburst_d = t.burst;
        arvalid_d = 1'b1;
        do @(negedge clk); while (!m.arready);
        cyc();
        arvalid_d = 1'b0;
    endtask

    // ---------------------------------------------------------------- R
    task automatic collect_r(axi_txn t);
        bit last;
        forever begin
            rready_d = !roll(r_stall_pct);
            @(negedge clk);
            last = 0;
            if (m.rvalid && rready_d) begin
                t.rsp_id = m.rid;
                t.rdata.push_back(m.rdata);
                t.rresp.push_back(m.rresp);
                last = m.rlast;
            end
            cyc();
            if (last) break;
        end
        rready_d = 1'b0;
    endtask

    // ---------------------------------------------------------------- engines
    initial begin : write_engine
        axi_txn t;
        @(posedge rst_n);
        cyc();
        forever begin
            while (wq.size() == 0) cyc();
            t = wq.pop_front();
            wr_active = 1;
            repeat ($urandom_range(0, issue_gap_max)) cyc();
            t.t_start = $time;
            fork
                drive_aw(t);
                drive_w(t);
            join
            collect_b(t);
            t.t_end = $time;
            t.done  = 1;
            writes_done++;
            wr_active = 0;
        end
    end

    initial begin : read_engine
        axi_txn t;
        @(posedge rst_n);
        cyc();
        forever begin
            while (rq.size() == 0) cyc();
            t = rq.pop_front();
            rd_active = 1;
            repeat ($urandom_range(0, issue_gap_max)) cyc();
            t.t_start = $time;
            drive_ar(t);
            collect_r(t);
            t.t_end = $time;
            t.done  = 1;
            reads_done++;
            rd_active = 0;
        end
    end

endmodule
