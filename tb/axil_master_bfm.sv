`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite master BFM + light protocol checks
// =============================================================================
// write(): drives AW and W with an independent random delay on each, so the
//          slave sees AW-first, W-first and simultaneous orderings
// read():  single read; BREADY / RREADY are randomly stalled
// Timing discipline: drive 1 ns after the rising edge, sample on falling edge.
// =============================================================================
module axil_master_bfm (
    input logic         clk,
    input logic         rst_n,
    axi4_lite_if.master m
);

    logic [31:0] awaddr_d  = '0;
    logic        awvalid_d = 1'b0;
    logic [31:0] wdata_d   = '0;
    logic [3:0]  wstrb_d   = '0;
    logic        wvalid_d  = 1'b0;
    logic        bready_d  = 1'b0;
    logic [31:0] araddr_d  = '0;
    logic        arvalid_d = 1'b0;
    logic        rready_d  = 1'b0;

    assign m.awaddr = awaddr_d;  assign m.awvalid = awvalid_d;
    assign m.wdata  = wdata_d;   assign m.wstrb   = wstrb_d;   assign m.wvalid = wvalid_d;
    assign m.bready = bready_d;
    assign m.araddr = araddr_d;  assign m.arvalid = arvalid_d;
    assign m.rready = rready_d;

    int errors    = 0;
    int stall_pct = 30;

    task automatic cyc();
        @(posedge clk);
        #1;
    endtask

    task automatic write(input logic [31:0] addr, input logic [31:0] data,
                         input logic [3:0] strb, output logic [1:0] resp);
        bit got;
        cyc();                      // align to the drive point
        fork
            begin
                repeat ($urandom_range(0, 3)) cyc();
                awaddr_d = addr; awvalid_d = 1'b1;
                do @(negedge clk); while (!m.awready);
                cyc();
                awvalid_d = 1'b0;
            end
            begin
                repeat ($urandom_range(0, 3)) cyc();
                wdata_d = data; wstrb_d = strb; wvalid_d = 1'b1;
                do @(negedge clk); while (!m.wready);
                cyc();
                wvalid_d = 1'b0;
            end
        join
        forever begin
            bready_d = ($urandom_range(0, 99) >= stall_pct);
            @(negedge clk);
            got = m.bvalid && bready_d;
            if (got) resp = m.bresp;
            cyc();
            if (got) break;
        end
        bready_d = 1'b0;
    endtask

    task automatic read(input logic [31:0] addr, output logic [31:0] data,
                        output logic [1:0] resp);
        bit got;
        cyc();
        araddr_d = addr; arvalid_d = 1'b1;
        do @(negedge clk); while (!m.arready);
        cyc();
        arvalid_d = 1'b0;
        forever begin
            rready_d = ($urandom_range(0, 99) >= stall_pct);
            @(negedge clk);
            got = m.rvalid && rready_d;
            if (got) begin data = m.rdata; resp = m.rresp; end
            cyc();
            if (got) break;
        end
        rready_d = 1'b0;
    endtask

    // Slave-side output stability: BVALID/RVALID must hold, payload stable
    logic        p_bv = 0, p_br = 0, p_rv = 0, p_rr = 0;
    logic [1:0]  p_bresp;
    logic [33:0] p_r;
    always @(negedge clk) begin
        if (rst_n) begin
            if (p_bv && !p_br && (!m.bvalid || m.bresp != p_bresp)) begin
                $display("[%0t] ERROR [AXIL] B channel changed while stalled", $time); errors++;
            end
            if (p_rv && !p_rr && (!m.rvalid || {m.rdata, m.rresp} != p_r)) begin
                $display("[%0t] ERROR [AXIL] R channel changed while stalled", $time); errors++;
            end
        end
        p_bv <= m.bvalid; p_br <= m.bready; p_bresp <= m.bresp;
        p_rv <= m.rvalid; p_rr <= m.rready; p_r <= {m.rdata, m.rresp};
    end

endmodule
