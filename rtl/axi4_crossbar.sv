`timescale 1ns/1ps

module axi4_crossbar #(
    parameter int NUM_MASTERS = 2,
    parameter int NUM_SLAVES  = 3,
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int ID_WIDTH    = 4,
    parameter bit REG_SLICE   = 1'b1
)(
    input  logic clk,
    input  logic rst_n,
 
    axi4_if.slave  master_ports [NUM_MASTERS],  
    axi4_if.master slave_ports  [NUM_SLAVES], 
 
    //one cycle status pulses for the AXI4-Lite control plane
    output logic [NUM_MASTERS-1:0] stat_aw_handshake,
    output logic [NUM_MASTERS-1:0] stat_ar_handshake,
    output logic [NUM_MASTERS-1:0] stat_aw_decerr,   
    output logic [NUM_MASTERS-1:0] stat_ar_decerr    
);
 
    localparam int STRB_WIDTH = DATA_WIDTH / 8;
    localparam int MW         = $clog2(NUM_MASTERS);   
    localparam int SW         = $clog2(NUM_SLAVES);
 
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;
 
    // Packed payload widths used by the register slices
    localparam int AX_W = ID_WIDTH + ADDR_WIDTH + 8 + 3 + 2;
    localparam int W_W  = DATA_WIDTH + STRB_WIDTH + 1;        
    localparam int B_W  = ID_WIDTH + 2;                        
    localparam int R_W  = ID_WIDTH + DATA_WIDTH + 2 + 1;       
 
    //  Master-side signal arrays (m_*)

    logic [ID_WIDTH-1:0]   m_awid    [NUM_MASTERS];
    logic [ADDR_WIDTH-1:0] m_awaddr  [NUM_MASTERS];
    logic [7:0]            m_awlen   [NUM_MASTERS];
    logic [2:0]            m_awsize  [NUM_MASTERS];
    logic [1:0]            m_awburst [NUM_MASTERS];
    logic                  m_awvalid [NUM_MASTERS];
    logic                  m_awready [NUM_MASTERS];
 
    logic [DATA_WIDTH-1:0] m_wdata   [NUM_MASTERS];
    logic [STRB_WIDTH-1:0] m_wstrb   [NUM_MASTERS];
    logic                  m_wlast   [NUM_MASTERS];
    logic                  m_wvalid  [NUM_MASTERS];
    logic                  m_wready  [NUM_MASTERS];
 
    logic [ID_WIDTH-1:0]   m_bid     [NUM_MASTERS];
    logic [1:0]            m_bresp   [NUM_MASTERS];
    logic                  m_bvalid  [NUM_MASTERS];
    logic                  m_bready  [NUM_MASTERS];
 
    logic [ID_WIDTH-1:0]   m_arid    [NUM_MASTERS];
    logic [ADDR_WIDTH-1:0] m_araddr  [NUM_MASTERS];
    logic [7:0]            m_arlen   [NUM_MASTERS];
    logic [2:0]            m_arsize  [NUM_MASTERS];
    logic [1:0]            m_arburst [NUM_MASTERS];
    logic                  m_arvalid [NUM_MASTERS];
    logic                  m_arready [NUM_MASTERS];
 
    logic [ID_WIDTH-1:0]   m_rid     [NUM_MASTERS];
    logic [DATA_WIDTH-1:0] m_rdata   [NUM_MASTERS];
    logic [1:0]            m_rresp   [NUM_MASTERS];
    logic                  m_rlast   [NUM_MASTERS];
    logic                  m_rvalid  [NUM_MASTERS];
    logic                  m_rready  [NUM_MASTERS];
 
     //  Core slave-side signal arrays

    logic [ID_WIDTH-1:0]   c_awid    [NUM_SLAVES];
    logic [ADDR_WIDTH-1:0] c_awaddr  [NUM_SLAVES];
    logic [7:0]            c_awlen   [NUM_SLAVES];
    logic [2:0]            c_awsize  [NUM_SLAVES];
    logic [1:0]            c_awburst [NUM_SLAVES];
    logic                  c_awvalid [NUM_SLAVES];
    logic                  c_awready [NUM_SLAVES];
 
    logic [DATA_WIDTH-1:0] c_wdata   [NUM_SLAVES];
    logic [STRB_WIDTH-1:0] c_wstrb   [NUM_SLAVES];
    logic                  c_wlast   [NUM_SLAVES];
    logic                  c_wvalid  [NUM_SLAVES];
    logic                  c_wready  [NUM_SLAVES];
 
    logic [ID_WIDTH-1:0]   c_bid     [NUM_SLAVES];
    logic [1:0]            c_bresp   [NUM_SLAVES];
    logic                  c_bvalid  [NUM_SLAVES];
    logic                  c_bready  [NUM_SLAVES];
 
    logic [ID_WIDTH-1:0]   c_arid    [NUM_SLAVES];
    logic [ADDR_WIDTH-1:0] c_araddr  [NUM_SLAVES];
    logic [7:0]            c_arlen   [NUM_SLAVES];
    logic [2:0]            c_arsize  [NUM_SLAVES];
    logic [1:0]            c_arburst [NUM_SLAVES];
    logic                  c_arvalid [NUM_SLAVES];
    logic                  c_arready [NUM_SLAVES];
 
    logic [ID_WIDTH-1:0]   c_rid     [NUM_SLAVES];
    logic [DATA_WIDTH-1:0] c_rdata   [NUM_SLAVES];
    logic [1:0]            c_rresp   [NUM_SLAVES];
    logic                  c_rlast   [NUM_SLAVES];
    logic                  c_rvalid  [NUM_SLAVES];
    logic                  c_rready  [NUM_SLAVES];
 
    genvar gm, gs;
 

    //  Interface to array connections (master ports)
    
    generate
        for (gm = 0; gm < NUM_MASTERS; gm++) begin : g_mport
            assign m_awid[gm]    = master_ports[gm].awid;
            assign m_awaddr[gm]  = master_ports[gm].awaddr;
            assign m_awlen[gm]   = master_ports[gm].awlen;
            assign m_awsize[gm]  = master_ports[gm].awsize;
            assign m_awburst[gm] = master_ports[gm].awburst;
            assign m_awvalid[gm] = master_ports[gm].awvalid;
            assign master_ports[gm].awready = m_awready[gm];
 
            assign m_wdata[gm]   = master_ports[gm].wdata;
            assign m_wstrb[gm]   = master_ports[gm].wstrb;
            assign m_wlast[gm]   = master_ports[gm].wlast;
            assign m_wvalid[gm]  = master_ports[gm].wvalid;
            assign master_ports[gm].wready = m_wready[gm];
 
            assign master_ports[gm].bid    = m_bid[gm];
            assign master_ports[gm].bresp  = m_bresp[gm];
            assign master_ports[gm].bvalid = m_bvalid[gm];
            assign m_bready[gm]  = master_ports[gm].bready;
 
            assign m_arid[gm]    = master_ports[gm].arid;
            assign m_araddr[gm]  = master_ports[gm].araddr;
            assign m_arlen[gm]   = master_ports[gm].arlen;
            assign m_arsize[gm]  = master_ports[gm].arsize;
            assign m_arburst[gm] = master_ports[gm].arburst;
            assign m_arvalid[gm] = master_ports[gm].arvalid;
            assign master_ports[gm].arready = m_arready[gm];
 
            assign master_ports[gm].rid    = m_rid[gm];
            assign master_ports[gm].rdata  = m_rdata[gm];
            assign master_ports[gm].rresp  = m_rresp[gm];
            assign master_ports[gm].rlast  = m_rlast[gm];
            assign master_ports[gm].rvalid = m_rvalid[gm];
            assign m_rready[gm]  = master_ports[gm].rready;
        end
    endgenerate
 
       //  Interface to array connections (slave ports), with slicing if
       //  required
      generate
        for (gs = 0; gs < NUM_SLAVES; gs++) begin : g_sport
            if (REG_SLICE) begin : g_slice
                logic [AX_W-1:0] aw_q, ar_q;
                logic [W_W-1:0]  w_q;
                logic [B_W-1:0]  b_q;
                logic [R_W-1:0]  r_q;
 
                // ---- Forward channels: core -> slice -> slave ----
                skid_buffer #(.DATA_WIDTH(AX_W)) u_aw_slice (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .in_valid  (c_awvalid[gs]),
                    .in_ready  (c_awready[gs]),
                    .in_data   ({c_awid[gs], c_awaddr[gs], c_awlen[gs], c_awsize[gs], c_awburst[gs]}),
                    .out_valid (slave_ports[gs].awvalid),
                    .out_ready (slave_ports[gs].awready),
                    .out_data  (aw_q)
                );
                assign {slave_ports[gs].awid,  slave_ports[gs].awaddr, slave_ports[gs].awlen,
                        slave_ports[gs].awsize, slave_ports[gs].awburst} = aw_q;
 
                skid_buffer #(.DATA_WIDTH(W_W)) u_w_slice (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .in_valid  (c_wvalid[gs]),
                    .in_ready  (c_wready[gs]),
                    .in_data   ({c_wdata[gs], c_wstrb[gs], c_wlast[gs]}),
                    .out_valid (slave_ports[gs].wvalid),
                    .out_ready (slave_ports[gs].wready),
                    .out_data  (w_q)
                );
                assign {slave_ports[gs].wdata, slave_ports[gs].wstrb, slave_ports[gs].wlast} = w_q;
 
                skid_buffer #(.DATA_WIDTH(AX_W)) u_ar_slice (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .in_valid  (c_arvalid[gs]),
                    .in_ready  (c_arready[gs]),
                    .in_data   ({c_arid[gs], c_araddr[gs], c_arlen[gs], c_arsize[gs], c_arburst[gs]}),
                    .out_valid (slave_ports[gs].arvalid),
                    .out_ready (slave_ports[gs].arready),
                    .out_data  (ar_q)
                );
                assign {slave_ports[gs].arid,  slave_ports[gs].araddr, slave_ports[gs].arlen,
                        slave_ports[gs].arsize, slave_ports[gs].arburst} = ar_q;
 
                // Reverse channels: slave -> slice -> core
                skid_buffer #(.DATA_WIDTH(B_W)) u_b_slice (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .in_valid  (slave_ports[gs].bvalid),
                    .in_ready  (slave_ports[gs].bready),
                    .in_data   ({slave_ports[gs].bid, slave_ports[gs].bresp}),
                    .out_valid (c_bvalid[gs]),
                    .out_ready (c_bready[gs]),
                    .out_data  (b_q)
                );
                assign {c_bid[gs], c_bresp[gs]} = b_q;
 
                skid_buffer #(.DATA_WIDTH(R_W)) u_r_slice (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .in_valid  (slave_ports[gs].rvalid),
                    .in_ready  (slave_ports[gs].rready),
                    .in_data   ({slave_ports[gs].rid, slave_ports[gs].rdata,
                                 slave_ports[gs].rresp, slave_ports[gs].rlast}),
                    .out_valid (c_rvalid[gs]),
                    .out_ready (c_rready[gs]),
                    .out_data  (r_q)
                );
                assign {c_rid[gs], c_rdata[gs], c_rresp[gs], c_rlast[gs]} = r_q;
 
            end else begin : g_direct
                assign slave_ports[gs].awid    = c_awid[gs];
                assign slave_ports[gs].awaddr  = c_awaddr[gs];
                assign slave_ports[gs].awlen   = c_awlen[gs];
                assign slave_ports[gs].awsize  = c_awsize[gs];
                assign slave_ports[gs].awburst = c_awburst[gs];
                assign slave_ports[gs].awvalid = c_awvalid[gs];
                assign c_awready[gs]           = slave_ports[gs].awready;
 
                assign slave_ports[gs].wdata   = c_wdata[gs];
                assign slave_ports[gs].wstrb   = c_wstrb[gs];
                assign slave_ports[gs].wlast   = c_wlast[gs];
                assign slave_ports[gs].wvalid  = c_wvalid[gs];
                assign c_wready[gs]            = slave_ports[gs].wready;
 
                assign c_bid[gs]               = slave_ports[gs].bid;
                assign c_bresp[gs]             = slave_ports[gs].bresp;
                assign c_bvalid[gs]            = slave_ports[gs].bvalid;
                assign slave_ports[gs].bready  = c_bready[gs];
 
                assign slave_ports[gs].arid    = c_arid[gs];
                assign slave_ports[gs].araddr  = c_araddr[gs];
                assign slave_ports[gs].arlen   = c_arlen[gs];
                assign slave_ports[gs].arsize  = c_arsize[gs];
                assign slave_ports[gs].arburst = c_arburst[gs];
                assign slave_ports[gs].arvalid = c_arvalid[gs];
                assign c_arready[gs]           = slave_ports[gs].arready;
 
                assign c_rid[gs]               = slave_ports[gs].rid;
                assign c_rdata[gs]             = slave_ports[gs].rdata;
                assign c_rresp[gs]             = slave_ports[gs].rresp;
                assign c_rlast[gs]             = slave_ports[gs].rlast;
                assign c_rvalid[gs]            = slave_ports[gs].rvalid;
                assign slave_ports[gs].rready  = c_rready[gs];
            end
        end
    endgenerate
 
     //Address decoding (one decoder per master, per direction)
    logic [SW-1:0] aw_sel [NUM_MASTERS];
    logic          aw_err [NUM_MASTERS];
    logic [SW-1:0] ar_sel [NUM_MASTERS];
    logic          ar_err [NUM_MASTERS];
 
    generate
        for (gm = 0; gm < NUM_MASTERS; gm++) begin : g_dec
            address_decoder #(.ADDR_WIDTH(ADDR_WIDTH), .NUM_SLAVES(NUM_SLAVES)) u_aw_dec (
                .addr         (m_awaddr[gm]),
                .error        (aw_err[gm]),
                .slave_select (aw_sel[gm])
            );
            address_decoder #(.ADDR_WIDTH(ADDR_WIDTH), .NUM_SLAVES(NUM_SLAVES)) u_ar_dec (
                .addr         (m_araddr[gm]),
                .error        (ar_err[gm]),
                .slave_select (ar_sel[gm])
            );
        end
    endgenerate
 
    //  (W) - WRITE PATH
 
    // Per-master write state
    logic                mw_busy  [NUM_MASTERS];   // AW accepted, B not yet delivered
    logic                mw_err   [NUM_MASTERS];   // outstanding write is a DECERR
    logic                mw_wdone [NUM_MASTERS];   // WLAST accepted from this master
    logic [SW-1:0]       mw_slave [NUM_MASTERS];   // target slave
    logic [ID_WIDTH-1:0] mw_id    [NUM_MASTERS];   // AWID (needed for DECERR response)
 
    //Per-slave write state
    logic                sw_busy  [NUM_SLAVES];    // AW sent, B not yet accepted
    logic                sw_wact  [NUM_SLAVES];    // W beats still to be forwarded
    logic [MW-1:0]       sw_owner [NUM_SLAVES];    // master that owns this write
 
    // AW arbitration
    logic [NUM_MASTERS-1:0] aw_req      [NUM_SLAVES];
    logic [NUM_MASTERS-1:0] aw_grant    [NUM_SLAVES];
    logic [MW-1:0]          aw_win      [NUM_SLAVES];
    logic                   aw_hold     [NUM_SLAVES];
    logic [MW-1:0]          aw_hold_idx [NUM_SLAVES];
    logic                   c_aw_hs     [NUM_SLAVES];
 
    // Request vector per slave. While a grant is held (slave-side VALID shown
    // but not yet accepted) only the held master may request, so the
    // arbiter's grant and the payload cannot change
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin
            aw_req[j] = '0;
            for (int k = 0; k < NUM_MASTERS; k++) begin
                if (m_awvalid[k] && !aw_err[k] && aw_sel[k] == SW'(j) &&
                    !mw_busy[k] && !sw_busy[j])
                    aw_req[j][k] = 1'b1;
            end
            if (aw_hold[j])
                aw_req[j] = aw_req[j] & (NUM_MASTERS'(1) << aw_hold_idx[j]);
        end
    end
 
    generate
        for (gs = 0; gs < NUM_SLAVES; gs++) begin : g_aw_arb
            round_robin_arbiter #(.NUM_REQ(NUM_MASTERS)) u_arb (
                .clk   (clk),
                .rst_n (rst_n),
                .req   (aw_req[gs]),
                .done  (c_aw_hs[gs]),
                .grant (aw_grant[gs])
            );
        end
    endgenerate
 
    // Winner index + AW mux to the core slave side
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin
            aw_win[j] = '0;
            for (int k = 0; k < NUM_MASTERS; k++)
                if (aw_grant[j][k]) aw_win[j] = MW'(k);
 
            c_awvalid[j] = |aw_grant[j];
            c_awid[j]    = m_awid[aw_win[j]];
            c_awaddr[j]  = m_awaddr[aw_win[j]];
            c_awlen[j]   = m_awlen[aw_win[j]];
            c_awsize[j]  = m_awsize[aw_win[j]];
            c_awburst[j] = m_awburst[aw_win[j]];
            c_aw_hs[j]   = c_awvalid[j] && c_awready[j];
        end
    end
 
    // AWREADY back to masters
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            if (mw_busy[m])
                m_awready[m] = 1'b0;
            else if (aw_err[m])
                m_awready[m] = 1'b1;
            else
                m_awready[m] = aw_grant[aw_sel[m]][m] && c_awready[aw_sel[m]];
        end
    end
 
    // W path muxing
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin
            c_wvalid[j] = sw_wact[j] && m_wvalid[sw_owner[j]];
            c_wdata[j]  = m_wdata[sw_owner[j]];
            c_wstrb[j]  = m_wstrb[sw_owner[j]];
            c_wlast[j]  = m_wlast[sw_owner[j]];
        end
    end
 
    // WREADY back to masters
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            m_wready[m] = 1'b0;
            if (mw_busy[m] && !mw_wdone[m]) begin
                if (mw_err[m])
                    m_wready[m] = 1'b1;
                else
                    m_wready[m] = sw_wact[mw_slave[m]] && c_wready[mw_slave[m]];
            end
        end
    end
 
    // B signal routing
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            m_bvalid[m] = 1'b0;
            m_bid[m]    = mw_id[m];
            m_bresp[m]  = RESP_OKAY;
            if (mw_busy[m] && mw_wdone[m]) begin
                if (mw_err[m]) begin
                    m_bvalid[m] = 1'b1;
                    m_bresp[m]  = RESP_DECERR;
                end else begin
                    m_bvalid[m] = c_bvalid[mw_slave[m]];
                    m_bid[m]    = c_bid[mw_slave[m]];
                    m_bresp[m]  = c_bresp[mw_slave[m]];
                end
            end
        end
        for (int j = 0; j < NUM_SLAVES; j++)
            c_bready[j] = sw_busy[j] && !sw_wact[j] && m_bready[sw_owner[j]];
    end
 
    // Write-path registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                mw_busy[m]  <= 1'b0;
                mw_err[m]   <= 1'b0;
                mw_wdone[m] <= 1'b0;
                mw_slave[m] <= '0;
                mw_id[m]    <= '0;
            end
            for (int j = 0; j < NUM_SLAVES; j++) begin
                sw_busy[j]     <= 1'b0;
                sw_wact[j]     <= 1'b0;
                sw_owner[j]    <= '0;
                aw_hold[j]     <= 1'b0;
                aw_hold_idx[j] <= '0;
            end
        end else begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                if (m_awvalid[m] && m_awready[m]) begin
                    mw_busy[m]  <= 1'b1;
                    mw_err[m]   <= aw_err[m];
                    mw_wdone[m] <= 1'b0;
                    mw_slave[m] <= aw_sel[m];
                    mw_id[m]    <= m_awid[m];
                end
                if (m_wvalid[m] && m_wready[m] && m_wlast[m])
                    mw_wdone[m] <= 1'b1;
                if (m_bvalid[m] && m_bready[m])
                    mw_busy[m] <= 1'b0;
            end
            for (int j = 0; j < NUM_SLAVES; j++) begin
                if (c_aw_hs[j]) begin
                    sw_busy[j]  <= 1'b1;
                    sw_wact[j]  <= 1'b1;
                    sw_owner[j] <= aw_win[j];
                end
                if (c_wvalid[j] && c_wready[j] && c_wlast[j])
                    sw_wact[j] <= 1'b0;
                if (c_bvalid[j] && c_bready[j])
                    sw_busy[j] <= 1'b0;
 
                //freeze the winner while VALID waits for READY
                if (!aw_hold[j]) begin
                    if (c_awvalid[j] && !c_awready[j]) begin
                        aw_hold[j]     <= 1'b1;
                        aw_hold_idx[j] <= aw_win[j];
                    end
                end else if (c_aw_hs[j]) begin
                    aw_hold[j] <= 1'b0;
                end
            end
        end
    end
 
    //  READ PATH
 
    //Per-master read state
    logic                mr_busy  [NUM_MASTERS]; 
    logic                mr_err   [NUM_MASTERS];   
    logic [SW-1:0]       mr_slave [NUM_MASTERS];
    logic [ID_WIDTH-1:0] mr_id    [NUM_MASTERS];
    logic [7:0]          mr_len   [NUM_MASTERS];   
    logic [7:0]          mr_cnt   [NUM_MASTERS];  
 
    //Per-slave read state
    logic                sr_busy  [NUM_SLAVES];
    logic [MW-1:0]       sr_owner [NUM_SLAVES];
 
    //AR arbitration
    logic [NUM_MASTERS-1:0] ar_req      [NUM_SLAVES];
    logic [NUM_MASTERS-1:0] ar_grant    [NUM_SLAVES];
    logic [MW-1:0]          ar_win      [NUM_SLAVES];
    logic                   ar_hold     [NUM_SLAVES];
    logic [MW-1:0]          ar_hold_idx [NUM_SLAVES];
    logic                   c_ar_hs     [NUM_SLAVES];
 
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin
            ar_req[j] = '0;
            for (int k = 0; k < NUM_MASTERS; k++) begin
                if (m_arvalid[k] && !ar_err[k] && ar_sel[k] == SW'(j) &&
                    !mr_busy[k] && !sr_busy[j])
                    ar_req[j][k] = 1'b1;
            end
            if (ar_hold[j])
                ar_req[j] = ar_req[j] & (NUM_MASTERS'(1) << ar_hold_idx[j]);
        end
    end
 
    generate
        for (gs = 0; gs < NUM_SLAVES; gs++) begin : g_ar_arb
            round_robin_arbiter #(.NUM_REQ(NUM_MASTERS)) u_arb (
                .clk   (clk),
                .rst_n (rst_n),
                .req   (ar_req[gs]),
                .done  (c_ar_hs[gs]),
                .grant (ar_grant[gs])
            );
        end
    endgenerate
 
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin
            ar_win[j] = '0;
            for (int k = 0; k < NUM_MASTERS; k++)
                if (ar_grant[j][k]) ar_win[j] = MW'(k);
 
            c_arvalid[j] = |ar_grant[j];
            c_arid[j]    = m_arid[ar_win[j]];
            c_araddr[j]  = m_araddr[ar_win[j]];
            c_arlen[j]   = m_arlen[ar_win[j]];
            c_arsize[j]  = m_arsize[ar_win[j]];
            c_arburst[j] = m_arburst[ar_win[j]];
            c_ar_hs[j]   = c_arvalid[j] && c_arready[j];
        end
    end
 
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            if (mr_busy[m])
                m_arready[m] = 1'b0;
            else if (ar_err[m])
                m_arready[m] = 1'b1;
            else
                m_arready[m] = ar_grant[ar_sel[m]][m] && c_arready[ar_sel[m]];
        end
    end
 
    // R signal routing
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            m_rvalid[m] = 1'b0;
            m_rid[m]    = mr_id[m];
            m_rdata[m]  = '0;
            m_rresp[m]  = RESP_OKAY;
            m_rlast[m]  = 1'b0;
            if (mr_busy[m]) begin
                if (mr_err[m]) begin
                    m_rvalid[m] = 1'b1;
                    m_rresp[m]  = RESP_DECERR;
                    m_rlast[m]  = (mr_cnt[m] == mr_len[m]);
                end else begin
                    m_rvalid[m] = c_rvalid[mr_slave[m]];
                    m_rid[m]    = c_rid[mr_slave[m]];
                    m_rdata[m]  = c_rdata[mr_slave[m]];
                    m_rresp[m]  = c_rresp[mr_slave[m]];
                    m_rlast[m]  = c_rlast[mr_slave[m]];
                end
            end
        end
        for (int j = 0; j < NUM_SLAVES; j++)
            c_rready[j] = sr_busy[j] && m_rready[sr_owner[j]];
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                mr_busy[m]  <= 1'b0;
                mr_err[m]   <= 1'b0;
                mr_slave[m] <= '0;
                mr_id[m]    <= '0;
                mr_len[m]   <= '0;
                mr_cnt[m]   <= '0;
            end
            for (int j = 0; j < NUM_SLAVES; j++) begin
                sr_busy[j]     <= 1'b0;
                sr_owner[j]    <= '0;
                ar_hold[j]     <= 1'b0;
                ar_hold_idx[j] <= '0;
            end
        end else begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                if (m_arvalid[m] && m_arready[m]) begin
                    mr_busy[m]  <= 1'b1;
                    mr_err[m]   <= ar_err[m];
                    mr_slave[m] <= ar_sel[m];
                    mr_id[m]    <= m_arid[m];
                    mr_len[m]   <= m_arlen[m];
                    mr_cnt[m]   <= '0;
                end
                if (m_rvalid[m] && m_rready[m]) begin
                    mr_cnt[m] <= mr_cnt[m] + 8'd1;
                    if (m_rlast[m]) mr_busy[m] <= 1'b0;
                end
            end
            for (int j = 0; j < NUM_SLAVES; j++) begin
                if (c_ar_hs[j]) begin
                    sr_busy[j]  <= 1'b1;
                    sr_owner[j] <= ar_win[j];
                end
                if (c_rvalid[j] && c_rready[j] && c_rlast[j])
                    sr_busy[j] <= 1'b0;
 
                if (!ar_hold[j]) begin
                    if (c_arvalid[j] && !c_arready[j]) begin
                        ar_hold[j]     <= 1'b1;
                        ar_hold_idx[j] <= ar_win[j];
                    end
                end else if (c_ar_hs[j]) begin
                    ar_hold[j] <= 1'b0;
                end
            end
        end
    end
 
    //  Ready/!Ready outputs
    always_comb begin
        for (int m = 0; m < NUM_MASTERS; m++) begin
            stat_aw_handshake[m] = m_awvalid[m] && m_awready[m];
            stat_ar_handshake[m] = m_arvalid[m] && m_arready[m];
            stat_aw_decerr[m]    = m_awvalid[m] && m_awready[m] && aw_err[m];
            stat_ar_decerr[m]    = m_arvalid[m] && m_arready[m] && ar_err[m];
        end
    end
 
endmodule
 
