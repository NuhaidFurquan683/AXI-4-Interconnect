`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite Control Plane for the AXI4 Crossbar
// =============================================================================
// 32-bit register file, AXI4-Lite slave.
//
// Register map (byte offsets, only ADDR[7:0] decoded, up to 8 masters)
//   0x00        VERSION     RO   32'h0001_0000
//   0x04        CONFIG      RO   {16'(NUM_SLAVES), 16'(NUM_MASTERS)}
//   0x08        CONTROL     RW   [0] COUNT_EN  (reset 1) counters increment when 1
//                                [1] CLEAR     write 1 to zero all counters (reads 0)
//   0x0C        SCRATCH     RW   32-bit scratch register (byte-strobed)
//   0x40 + 4*m  AW_COUNT[m] RO   write transactions accepted from master m
//   0x60 + 4*m  AR_COUNT[m] RO   read transactions accepted from master m
//   0x80 + 4*m  ERR_COUNT[m]RO   DECERR transactions (read + write) from master m
//
// Responses: OKAY for valid accesses, SLVERR for unaligned/unmapped addresses
// and for writes to read-only registers.
//
// Protocol: AW and W are accepted independently (either order); the register
// write happens once both are held, then B is issued. Reads have one cycle of
// latency: AR is accepted whenever no R response is pending.
// =============================================================================

module axi4_lite_control #(
    parameter int NUM_MASTERS = 2,      // up to 8
    parameter int NUM_SLAVES  = 3
)(
    input  logic clk,
    input  logic rst_n,

    axi4_lite_if.slave ctrl_port,     // DATA_WIDTH must be 32

    input  logic [NUM_MASTERS-1:0] aw_handshake,
    input  logic [NUM_MASTERS-1:0] ar_handshake,
    input  logic [NUM_MASTERS-1:0] aw_decerr,
    input  logic [NUM_MASTERS-1:0] ar_decerr
);

    localparam logic [31:0] VERSION     = 32'h0001_0000;
    localparam logic [1:0]  RESP_OKAY   = 2'b00;
    localparam logic [1:0]  RESP_SLVERR = 2'b10;

    // =========================================================================
    //  Registers and counters
    // =========================================================================
    logic        count_en;
    logic        clear_pulse;
    logic [31:0] scratch;
    logic [31:0] aw_cnt  [NUM_MASTERS];
    logic [31:0] ar_cnt  [NUM_MASTERS];
    logic [31:0] err_cnt [NUM_MASTERS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                aw_cnt[m]  <= '0;
                ar_cnt[m]  <= '0;
                err_cnt[m] <= '0;
            end
        end else if (clear_pulse) begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                aw_cnt[m]  <= '0;
                ar_cnt[m]  <= '0;
                err_cnt[m] <= '0;
            end
        end else if (count_en) begin
            for (int m = 0; m < NUM_MASTERS; m++) begin
                aw_cnt[m]  <= aw_cnt[m]  + 32'(aw_handshake[m]);
                ar_cnt[m]  <= ar_cnt[m]  + 32'(ar_handshake[m]);
                err_cnt[m] <= err_cnt[m] + 32'(aw_decerr[m]) + 32'(ar_decerr[m]);
            end
        end
    end

    // =========================================================================
    //  Write channel: AW and W captured independently, then B
    // =========================================================================
    logic                  aw_full, w_full;
    logic [7:0]            aw_addr_q;      // only the decoded offset is kept
    logic [31:0]           w_data_q;
    logic [3:0]            w_strb_q;
    logic                  bvalid_q;
    logic [1:0]            bresp_q;

    logic       wr_fire;
    logic [7:0] wa;
    assign wa      = aw_addr_q;
    assign wr_fire = aw_full && w_full && !bvalid_q;

    assign ctrl_port.awready = !aw_full;
    assign ctrl_port.wready  = !w_full;
    assign ctrl_port.bvalid  = bvalid_q;
    assign ctrl_port.bresp   = bresp_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_full     <= 1'b0;
            w_full      <= 1'b0;
            aw_addr_q   <= '0;
            w_data_q    <= '0;
            w_strb_q    <= '0;
            bvalid_q    <= 1'b0;
            bresp_q     <= RESP_OKAY;
            count_en    <= 1'b1;
            clear_pulse <= 1'b0;
            scratch     <= '0;
        end else begin
            clear_pulse <= 1'b0;                       // CLEAR is self-clearing

            if (ctrl_port.awvalid && !aw_full) begin
                aw_full   <= 1'b1;
                aw_addr_q <= ctrl_port.awaddr[7:0];
            end
            if (ctrl_port.wvalid && !w_full) begin
                w_full   <= 1'b1;
                w_data_q <= ctrl_port.wdata;
                w_strb_q <= ctrl_port.wstrb;
            end

            if (wr_fire) begin
                bvalid_q <= 1'b1;
                if (wa == 8'h08) begin                 // CONTROL
                    bresp_q <= RESP_OKAY;
                    if (w_strb_q[0]) begin
                        count_en    <= w_data_q[0];
                        clear_pulse <= w_data_q[1];
                    end
                end else if (wa == 8'h0C) begin        // SCRATCH
                    bresp_q <= RESP_OKAY;
                    for (int b = 0; b < 4; b++)
                        if (w_strb_q[b]) scratch[8*b +: 8] <= w_data_q[8*b +: 8];
                end else begin                         // RO or unmapped
                    bresp_q <= RESP_SLVERR;
                end
            end

            if (bvalid_q && ctrl_port.bready) begin
                bvalid_q <= 1'b0;
                aw_full  <= 1'b0;
                w_full   <= 1'b0;
            end
        end
    end

    // =========================================================================
    //  Read channel
    // =========================================================================
    logic        rvalid_q;
    logic [31:0] rdata_q;
    logic [1:0]  rresp_q;
    logic [31:0] rd_data;
    logic        rd_err;
    logic [7:0]  ra;
    logic [2:0]  ridx;
    logic        idx_ok;
    logic [31:0] aw_sel_cnt, ar_sel_cnt, err_sel_cnt;

    assign ra   = ctrl_port.araddr[7:0];
    assign ridx = ra[4:2];

    assign ctrl_port.arready = !rvalid_q;
    assign ctrl_port.rvalid  = rvalid_q;
    assign ctrl_port.rdata   = rdata_q;
    assign ctrl_port.rresp   = rresp_q;

    // Per-master counter select (loop avoids out-of-range array indexing)
    always_comb begin
        idx_ok      = 1'b0;
        aw_sel_cnt  = '0;
        ar_sel_cnt  = '0;
        err_sel_cnt = '0;
        for (int m = 0; m < NUM_MASTERS; m++) begin
            if (ridx == 3'(m)) begin
                idx_ok      = 1'b1;
                aw_sel_cnt  = aw_cnt[m];
                ar_sel_cnt  = ar_cnt[m];
                err_sel_cnt = err_cnt[m];
            end
        end
    end

    // Combinational register read decode (on the incoming AR address)
    always_comb begin
        rd_data = '0;
        rd_err  = 1'b0;
        if (ra[1:0] != 2'b00) begin
            rd_err = 1'b1;
        end else begin
            case (ra[7:5])
                3'd0: begin
                    case (ridx)
                        3'd0:    rd_data = VERSION;
                        3'd1:    rd_data = {16'(NUM_SLAVES), 16'(NUM_MASTERS)};
                        3'd2:    rd_data = {31'b0, count_en};
                        3'd3:    rd_data = scratch;
                        default: rd_err  = 1'b1;
                    endcase
                end
                3'd2: begin rd_data = aw_sel_cnt;  rd_err = !idx_ok; end
                3'd3: begin rd_data = ar_sel_cnt;  rd_err = !idx_ok; end
                3'd4: begin rd_data = err_sel_cnt; rd_err = !idx_ok; end
                default: rd_err = 1'b1;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid_q <= 1'b0;
            rdata_q  <= '0;
            rresp_q  <= RESP_OKAY;
        end else begin
            if (ctrl_port.arvalid && !rvalid_q) begin
                rvalid_q <= 1'b1;
                rdata_q  <= rd_data;
                rresp_q  <= rd_err ? RESP_SLVERR : RESP_OKAY;
            end else if (rvalid_q && ctrl_port.rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

endmodule

