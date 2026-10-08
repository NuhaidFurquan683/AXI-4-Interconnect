`timescale 1ns/1ps
// =============================================================================
// Blackboard (Zynq XC7Z007S) hardware test top for the AXI4 crossbar
// =============================================================================
//   2 x axi_traffic_gen  ->  axi4_crossbar (2x3)  ->  3 x axi_bram_slave
//   axi4_lite_control counters are read back over AXI4-Lite by a small
//   on-chip FSM and compared with what the generators actually issued.
//
// Controls
//   btn[0]   reset
//   sw[0]    RUN      (on: traffic runs; off: drain, then control-plane check)
//   sw[1]    STALL    random backpressure on every channel (masters + slaves)
//   sw[2]    DECERR   every 64th transaction targets the unmapped region
//   sw[11:8] display select (see below)
//
// LEDs
//   led[0] heartbeat while running      led[1] PASS (traffic done, 0 errors, ctrl OK)
//   led[2] data mismatch (sticky)       led[3] wrong BRESP/RRESP (sticky)
//   led[4] wrong ID / RLAST (sticky)    led[5] routed to wrong slave (sticky)
//   led[6] control-plane counter mismatch
//   led[7] control-plane check completed
//   led[8] master 0 active              led[9] master 1 active
//   RGB A: green = PASS, red = any error          RGB B: blue = running
//
// 7-segment display (sw[11:8])
//   0: throughput, data beats per cycle x 1000 (decimal), both masters, averaged
//      over 2^WIN_LOG2 cycles. 2000 = both masters moving one beat every cycle.
//   1: transactions completed, upper 16 bits (hex)
//   2: transactions completed, lower 16 bits (hex)
//   3: error count (hex)
//   4: DECERR responses seen (hex)
//   5: control-plane check: 600d = match, bAd0 = mismatch, 0000 = not run yet
//   6: master 0 throughput x 1000 (decimal)
//   7: master 1 throughput x 1000 (decimal)
//
// Clocking: by default the test runs directly on the board clock (pin H16).
// With USE_MMCM=1 an MMCM generates SYS_MHZ from CLK_IN_MHZ (VCO = 1000 MHz);
// legal SYS_MHZ: 100, 125, 160, 200, 250. CLK_IN_MHZ must match the board.
// =============================================================================
module axi4_xbar_hw_top #(
    parameter bit REG_SLICE      = 1'b1,
    parameter bit USE_MMCM       = 1'b0,
    parameter int CLK_IN_MHZ     = 100,
    parameter int SYS_MHZ        = 100,
    parameter int WIN_LOG2       = 20,
    parameter bit SEG_ACTIVE_LOW = 1'b1,
    parameter bit RGB_ACTIVE_LOW = 1'b0
)(
    input  logic        clk,
    input  logic [3:0]  btn,
    input  logic [11:0] sw,
    output logic [9:0]  led,
    output logic [2:0]  RGB_led_A,
    output logic [2:0]  RGB_led_B,
    output logic [3:0]  seg_an,
    output logic [7:0]  seg_cat
);

    localparam int NM = 2;
    localparam int NS = 3;

    // =========================================================================
    //  Clock and reset
    // =========================================================================
    logic sys_clk, mmcm_locked;

    generate
        if (USE_MMCM) begin : g_mmcm
`ifndef VERILATOR
            logic clk_fb, clk0;
            MMCME2_BASE #(
                .CLKIN1_PERIOD    (1000.0 / CLK_IN_MHZ),
                .CLKFBOUT_MULT_F  (1000.0 / CLK_IN_MHZ),
                .DIVCLK_DIVIDE    (1),
                .CLKOUT0_DIVIDE_F (1000.0 / SYS_MHZ)
            ) u_mmcm (
                .CLKIN1   (clk),
                .CLKFBIN  (clk_fb),
                .CLKFBOUT (clk_fb),
                .CLKOUT0  (clk0),
                .LOCKED   (mmcm_locked),
                .PWRDWN   (1'b0),
                .RST      (1'b0),
                .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
                .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
            );
            BUFG u_bufg (.I(clk0), .O(sys_clk));
`else
            assign sys_clk     = clk;
            assign mmcm_locked = 1'b1;
`endif
        end else begin : g_noclk
            assign sys_clk     = clk;
            assign mmcm_locked = 1'b1;
        end
    endgenerate

    // Power-on + button reset, synchronous release
    logic [3:0] rst_sync = 4'h0;
    logic       rst_n;
    always_ff @(posedge sys_clk) begin
        if (btn[0] || !mmcm_locked) rst_sync <= 4'h0;
        else                        rst_sync <= {rst_sync[2:0], 1'b1};
    end
    assign rst_n = rst_sync[3];

    // Switch synchronisers
    logic [11:0] sw_m, sw_s;
    always_ff @(posedge sys_clk) begin
        sw_m <= sw;
        sw_s <= sw_m;
    end
    logic run_sw, stall_en, decerr_en;
    assign run_sw    = sw_s[0];
    assign stall_en  = sw_s[1];
    assign decerr_en = sw_s[2];

    // =========================================================================
    //  Bus fabric
    // =========================================================================
    axi4_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .ID_WIDTH(4)) mif [NM] ();
    axi4_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .ID_WIDTH(4)) sif [NS] ();
    axi4_lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) cif ();

    logic [NM-1:0] st_aw, st_ar, st_awe, st_are;

    axi4_crossbar #(
        .NUM_MASTERS (NM),
        .NUM_SLAVES  (NS),
        .REG_SLICE   (REG_SLICE)
    ) u_xbar (
        .clk               (sys_clk),
        .rst_n             (rst_n),
        .master_ports      (mif),
        .slave_ports       (sif),
        .stat_aw_handshake (st_aw),
        .stat_ar_handshake (st_ar),
        .stat_aw_decerr    (st_awe),
        .stat_ar_decerr    (st_are)
    );

    axi4_lite_control #(.NUM_MASTERS(NM), .NUM_SLAVES(NS)) u_ctrl (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .ctrl_port    (cif),
        .aw_handshake (st_aw),
        .ar_handshake (st_ar),
        .aw_decerr    (st_awe),
        .ar_decerr    (st_are)
    );

    // ---- Traffic generators ----
    logic        gen_run, gen_clear;
    logic        g_idle   [NM];
    logic [31:0] g_txn    [NM];
    logic [31:0] g_aw     [NM];
    logic [31:0] g_ar     [NM];
    logic [31:0] g_decerr [NM];
    logic [31:0] g_err    [NM];
    logic        g_edata  [NM];
    logic        g_eresp  [NM];
    logic        g_eproto [NM];
    logic        g_bw     [NM];
    logic        g_br     [NM];

    axi_traffic_gen #(.MIDX(0), .SEED(32'h1357_9BDF)) u_gen0 (
        .clk(sys_clk), .rst_n(rst_n), .run(gen_run), .stall_en(stall_en), .decerr_en(decerr_en),
        .clear(gen_clear), .m(mif[0]), .idle(g_idle[0]), .txn_count(g_txn[0]), .aw_count(g_aw[0]),
        .ar_count(g_ar[0]), .decerr_count(g_decerr[0]), .err_count(g_err[0]), .err_data(g_edata[0]),
        .err_resp(g_eresp[0]), .err_proto(g_eproto[0]), .beat_w(g_bw[0]), .beat_r(g_br[0]));

    axi_traffic_gen #(.MIDX(1), .SEED(32'h2468_ACE1)) u_gen1 (
        .clk(sys_clk), .rst_n(rst_n), .run(gen_run), .stall_en(stall_en), .decerr_en(decerr_en),
        .clear(gen_clear), .m(mif[1]), .idle(g_idle[1]), .txn_count(g_txn[1]), .aw_count(g_aw[1]),
        .ar_count(g_ar[1]), .decerr_count(g_decerr[1]), .err_count(g_err[1]), .err_data(g_edata[1]),
        .err_resp(g_eresp[1]), .err_proto(g_eproto[1]), .beat_w(g_bw[1]), .beat_r(g_br[1]));

    // ---- Block-RAM slaves ----
    logic [NS-1:0] route_err;
    axi_bram_slave #(.SIDX(0), .SEED(32'hA5A5_0001)) u_ram0 (.clk(sys_clk), .rst_n(rst_n), .stall_en(stall_en), .s(sif[0]), .route_err(route_err[0]));
    axi_bram_slave #(.SIDX(1), .SEED(32'h5A5A_0002)) u_ram1 (.clk(sys_clk), .rst_n(rst_n), .stall_en(stall_en), .s(sif[1]), .route_err(route_err[1]));
    axi_bram_slave #(.SIDX(2), .SEED(32'h3C3C_0003)) u_ram2 (.clk(sys_clk), .rst_n(rst_n), .stall_en(stall_en), .s(sif[2]), .route_err(route_err[2]));

    // =========================================================================
    //  Test sequencer + AXI4-Lite control-plane checker
    // =========================================================================
    //  RUN rising : write CONTROL = 3 (clear counters), clear generators, start
    //  RUN falling: let generators finish, then read VERSION + 6 counters
    typedef enum logic [2:0] {T_IDLE, T_CLR, T_CLR_B, T_RUN, T_DRAIN, T_RD_A, T_RD_R, T_DONE} tst_t;
    tst_t tst;

    logic        l_awvalid, l_wvalid, l_bready, l_arvalid, l_rready;
    logic [31:0] l_araddr;
    logic [2:0]  rd_idx;
    logic        ctrl_checked, ctrl_bad, ran;

    assign cif.awaddr  = 32'h08;               // CONTROL
    assign cif.awvalid = l_awvalid;
    assign cif.wdata   = 32'h3;                // COUNT_EN=1, CLEAR=1
    assign cif.wstrb   = 4'hF;
    assign cif.wvalid  = l_wvalid;
    assign cif.bready  = l_bready;
    assign cif.araddr  = l_araddr;
    assign cif.arvalid = l_arvalid;
    assign cif.rready  = l_rready;

    // Readback plan: address and expected value for each step
    logic [31:0] exp_val;
    always_comb begin
        case (rd_idx)
            3'd0:    begin l_araddr = 32'h00; exp_val = 32'h0001_0000; end   // VERSION
            3'd1:    begin l_araddr = 32'h40; exp_val = g_aw[0];       end   // AW_COUNT[0]
            3'd2:    begin l_araddr = 32'h44; exp_val = g_aw[1];       end   // AW_COUNT[1]
            3'd3:    begin l_araddr = 32'h60; exp_val = g_ar[0];       end   // AR_COUNT[0]
            3'd4:    begin l_araddr = 32'h64; exp_val = g_ar[1];       end   // AR_COUNT[1]
            3'd5:    begin l_araddr = 32'h80; exp_val = g_decerr[0];   end   // ERR_COUNT[0]
            default: begin l_araddr = 32'h84; exp_val = g_decerr[1];   end   // ERR_COUNT[1]
        endcase
    end

    logic aw_ok, w_ok;
    assign gen_run = (tst == T_RUN);

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            tst <= T_IDLE;
            l_awvalid <= 1'b0; l_wvalid <= 1'b0; l_bready <= 1'b0;
            l_arvalid <= 1'b0; l_rready <= 1'b0;
            aw_ok <= 1'b0; w_ok <= 1'b0;
            rd_idx <= '0; ctrl_checked <= 1'b0; ctrl_bad <= 1'b0; ran <= 1'b0;
            gen_clear <= 1'b0;
        end else begin
            gen_clear <= 1'b0;
            case (tst)
                T_IDLE, T_DONE: if (run_sw) begin
                    l_awvalid <= 1'b1; l_wvalid <= 1'b1;
                    aw_ok <= 1'b0; w_ok <= 1'b0;
                    ctrl_checked <= 1'b0; ctrl_bad <= 1'b0;
                    gen_clear <= 1'b1;
                    tst <= T_CLR;
                end
                T_CLR: begin
                    if (cif.awvalid && cif.awready) begin l_awvalid <= 1'b0; aw_ok <= 1'b1; end
                    if (cif.wvalid  && cif.wready)  begin l_wvalid  <= 1'b0; w_ok  <= 1'b1; end
                    if (aw_ok && w_ok) begin l_bready <= 1'b1; tst <= T_CLR_B; end
                end
                T_CLR_B: if (cif.bvalid && cif.bready) begin
                    l_bready <= 1'b0;
                    ran      <= 1'b1;
                    tst      <= T_RUN;
                end
                T_RUN:   if (!run_sw) tst <= T_DRAIN;
                T_DRAIN: if (g_idle[0] && g_idle[1]) begin
                    rd_idx <= '0; l_arvalid <= 1'b1; tst <= T_RD_A;
                end
                T_RD_A: if (cif.arvalid && cif.arready) begin
                    l_arvalid <= 1'b0; l_rready <= 1'b1; tst <= T_RD_R;
                end
                T_RD_R: if (cif.rvalid && cif.rready) begin
                    l_rready <= 1'b0;
                    if (cif.rdata != exp_val || cif.rresp != 2'b00) ctrl_bad <= 1'b1;
                    if (rd_idx == 3'd6) begin
                        ctrl_checked <= 1'b1;
                        tst <= T_DONE;
                    end else begin
                        rd_idx <= rd_idx + 3'd1;
                        l_arvalid <= 1'b1;
                        tst <= T_RD_A;
                    end
                end
                default: tst <= T_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Throughput meter: data beats per 2^WIN_LOG2 cycles
    // =========================================================================
    logic [WIN_LOG2-1:0] win_cnt;
    logic [WIN_LOG2+1:0] acc0, acc1, thr0, thr1;     // per-master beat counts

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt <= '0; acc0 <= '0; acc1 <= '0; thr0 <= '0; thr1 <= '0;
        end else if (gen_run) begin
            win_cnt <= win_cnt + 1'b1;
            if (&win_cnt) begin
                thr0 <= acc0 + (WIN_LOG2+2)'(g_bw[0] | g_br[0]);
                thr1 <= acc1 + (WIN_LOG2+2)'(g_bw[1] | g_br[1]);
                acc0 <= '0;
                acc1 <= '0;
            end else begin
                acc0 <= acc0 + (WIN_LOG2+2)'(g_bw[0] | g_br[0]);
                acc1 <= acc1 + (WIN_LOG2+2)'(g_bw[1] | g_br[1]);
            end
        end else begin
            win_cnt <= '0; acc0 <= '0; acc1 <= '0;      // keep last measurement
        end
    end

    // beats/cycle x 1000 = beats * 1000 / 2^WIN_LOG2   (1000 = 1024 - 16 - 8)
    function automatic logic [15:0] per_mille(logic [WIN_LOG2+1:0] beats);
        logic [WIN_LOG2+13:0] p;
        p = ({12'b0, beats} << 10) - ({12'b0, beats} << 4) - ({12'b0, beats} << 3);
        return 16'(p >> WIN_LOG2);
    endfunction

    // Binary (0..9999) to 4 BCD digits, double dabble
    function automatic logic [15:0] to_bcd(logic [15:0] bin);
        logic [31:0] sh;
        sh = {16'b0, bin};
        for (int i = 0; i < 16; i++) begin
            for (int d = 0; d < 4; d++)
                if (sh[16 + 4*d +: 4] >= 4'd5) sh[16 + 4*d +: 4] = sh[16 + 4*d +: 4] + 4'd3;
            sh = sh << 1;
        end
        return sh[31:16];
    endfunction

    // =========================================================================
    //  Status
    // =========================================================================
    logic [31:0] txn_total, err_total, decerr_total;
    logic        any_err, pass;
    assign txn_total    = g_txn[0] + g_txn[1];
    assign err_total    = g_err[0] + g_err[1];
    assign decerr_total = g_decerr[0] + g_decerr[1];
    assign any_err      = g_edata[0] | g_edata[1] | g_eresp[0] | g_eresp[1] |
                          g_eproto[0] | g_eproto[1] | (|route_err) | ctrl_bad;
    assign pass         = ran && ctrl_checked && !any_err && (txn_total != 0);

    logic [25:0] hb = '0;
    always_ff @(posedge sys_clk) hb <= hb + 1'b1;

    assign led[0] = gen_run & hb[25];
    assign led[1] = pass;
    assign led[2] = g_edata[0] | g_edata[1];
    assign led[3] = g_eresp[0] | g_eresp[1];
    assign led[4] = g_eproto[0] | g_eproto[1];
    assign led[5] = |route_err;
    assign led[6] = ctrl_bad;
    assign led[7] = ctrl_checked;
    assign led[8] = !g_idle[0];
    assign led[9] = !g_idle[1];

    assign RGB_led_A = {3{RGB_ACTIVE_LOW}} ^ {1'b0, pass, any_err};    // {B, G, R}
    assign RGB_led_B = {3{RGB_ACTIVE_LOW}} ^ {gen_run, 2'b00};

    // =========================================================================
    //  Seven-segment display (4 digits, multiplexed)
    // =========================================================================
    logic [15:0] disp;
    always_comb begin
        case (sw_s[11:8])
            4'd0:    disp = to_bcd(per_mille(thr0) + per_mille(thr1));
            4'd1:    disp = txn_total[31:16];
            4'd2:    disp = txn_total[15:0];
            4'd3:    disp = err_total[15:0];
            4'd4:    disp = decerr_total[15:0];
            4'd5:    disp = !ctrl_checked ? 16'h0000 : (ctrl_bad ? 16'hBAD0 : 16'h600D);
            4'd6:    disp = to_bcd(per_mille(thr0));
            4'd7:    disp = to_bcd(per_mille(thr1));
            default: disp = 16'h0000;
        endcase
    end

    function automatic logic [6:0] hex7(logic [3:0] h);   // {g,f,e,d,c,b,a}, 1 = lit
        case (h)
            4'h0: return 7'b0111111;  4'h1: return 7'b0000110;
            4'h2: return 7'b1011011;  4'h3: return 7'b1001111;
            4'h4: return 7'b1100110;  4'h5: return 7'b1101101;
            4'h6: return 7'b1111101;  4'h7: return 7'b0000111;
            4'h8: return 7'b1111111;  4'h9: return 7'b1101111;
            4'hA: return 7'b1110111;  4'hB: return 7'b1111100;
            4'hC: return 7'b0111001;  4'hD: return 7'b1011110;
            4'hE: return 7'b1111001;  default: return 7'b1110001;
        endcase
    endfunction

    logic [17:0] scan = '0;
    always_ff @(posedge sys_clk) scan <= scan + 1'b1;
    logic [1:0] digit;
    assign digit = scan[17:16];

    logic [3:0] an_on;
    logic [7:0] cat_on;
    always_comb begin
        an_on  = 4'b0001 << digit;                         // digit 0 = rightmost
        cat_on = {1'b0, hex7(disp[4*digit +: 4])};         // {dp, g..a}
    end
    assign seg_an  = SEG_ACTIVE_LOW ? ~an_on  : an_on;
    assign seg_cat = SEG_ACTIVE_LOW ? ~cat_on : cat_on;

`ifdef AXI_HW_SIM
    // Simulation only: protocol checkers on every port (see tb/tb_hw_top.sv)
    axi_protocol_checker #(.NAME("HW_M0")) c_m0 (.clk(sys_clk), .rst_n(rst_n), .bus(mif[0]));
    axi_protocol_checker #(.NAME("HW_M1")) c_m1 (.clk(sys_clk), .rst_n(rst_n), .bus(mif[1]));
    axi_protocol_checker #(.NAME("HW_S0")) c_s0 (.clk(sys_clk), .rst_n(rst_n), .bus(sif[0]));
    axi_protocol_checker #(.NAME("HW_S1")) c_s1 (.clk(sys_clk), .rst_n(rst_n), .bus(sif[1]));
    axi_protocol_checker #(.NAME("HW_S2")) c_s2 (.clk(sys_clk), .rst_n(rst_n), .bus(sif[2]));
`endif

    // Unused inputs
    logic unused;
    assign unused = ^{btn[3:1], sw_s[7:3]};

endmodule
