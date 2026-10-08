`timescale 1ns/1ps
// =============================================================================
// Synthesis / timing harness for the AXI4 crossbar + AXI4-Lite control plane
// =============================================================================
// FOR TIMING ANALYSIS ONLY — not a functional top level.
// Every input is registered on entry and every output is registered on exit,
// so Vivado times real register-to-register paths through the crossbar
// (decode -> arbitrate -> mux -> ready return). This is what lets you compare
// REG_SLICE = 0 vs 1 fairly in an out-of-context run.
// =============================================================================
module axi4_xbar_synth_top #(
    parameter bit REG_SLICE = 1'b1,
    parameter int NM        = 2,
    parameter int NS        = 3
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [NM*140-1:0] m_in,    // master  -> crossbar (AW, W, BREADY, AR, RREADY)
    output logic [NM*50-1:0]  m_out,   // crossbar -> master  (AWREADY, WREADY, B, ARREADY, R)
    output logic [NS*140-1:0] s_out,   // crossbar -> slave
    input  logic [NS*50-1:0]  s_in,    // slave   -> crossbar
    input  logic [104:0]      c_in,    // AXI4-Lite master -> control plane
    output logic [40:0]       c_out    // control plane -> AXI4-Lite master
);

    localparam int FWD = 140;
    localparam int REV = 50;

    // ---------------- boundary registers ----------------
    logic [NM*FWD-1:0] m_in_q;
    logic [NM*REV-1:0] m_out_c;
    logic [NS*FWD-1:0] s_out_c;
    logic [NS*REV-1:0] s_in_q;
    logic [104:0]      c_in_q;
    logic [40:0]       c_out_c;

    always_ff @(posedge clk) begin
        m_in_q <= m_in;
        s_in_q <= s_in;
        c_in_q <= c_in;
        m_out  <= m_out_c;
        s_out  <= s_out_c;
        c_out  <= c_out_c;
    end

    // ---------------- DUT ----------------
    axi4_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .ID_WIDTH(4)) mif [NM] ();
    axi4_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .ID_WIDTH(4)) sif [NS] ();
    axi4_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cif ();

    logic [NM-1:0] st_aw, st_ar, st_awe, st_are;

    genvar g;
    generate
        for (g = 0; g < NM; g++) begin : g_m
            assign {mif[g].awid, mif[g].awaddr, mif[g].awlen, mif[g].awsize, mif[g].awburst, mif[g].awvalid,
                    mif[g].wdata, mif[g].wstrb, mif[g].wlast, mif[g].wvalid, mif[g].bready,
                    mif[g].arid, mif[g].araddr, mif[g].arlen, mif[g].arsize, mif[g].arburst, mif[g].arvalid,
                    mif[g].rready} = m_in_q[g*FWD +: FWD];
            assign m_out_c[g*REV +: REV] =
                   {mif[g].awready, mif[g].wready, mif[g].bid, mif[g].bresp, mif[g].bvalid,
                    mif[g].arready, mif[g].rid, mif[g].rdata, mif[g].rresp, mif[g].rlast, mif[g].rvalid};
        end
        for (g = 0; g < NS; g++) begin : g_s
            assign s_out_c[g*FWD +: FWD] =
                   {sif[g].awid, sif[g].awaddr, sif[g].awlen, sif[g].awsize, sif[g].awburst, sif[g].awvalid,
                    sif[g].wdata, sif[g].wstrb, sif[g].wlast, sif[g].wvalid, sif[g].bready,
                    sif[g].arid, sif[g].araddr, sif[g].arlen, sif[g].arsize, sif[g].arburst, sif[g].arvalid,
                    sif[g].rready};
            assign {sif[g].awready, sif[g].wready, sif[g].bid, sif[g].bresp, sif[g].bvalid,
                    sif[g].arready, sif[g].rid, sif[g].rdata, sif[g].rresp, sif[g].rlast, sif[g].rvalid}
                   = s_in_q[g*REV +: REV];
        end
    endgenerate

    assign {cif.awaddr, cif.awvalid, cif.wdata, cif.wstrb, cif.wvalid, cif.bready,
            cif.araddr, cif.arvalid, cif.rready} = c_in_q;
    assign c_out_c = {cif.awready, cif.wready, cif.bresp, cif.bvalid,
                      cif.arready, cif.rdata, cif.rresp, cif.rvalid};

    axi4_crossbar #(
        .NUM_MASTERS (NM),
        .NUM_SLAVES  (NS),
        .REG_SLICE   (REG_SLICE)
    ) u_xbar (
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

endmodule

