`timescale 1ns/1ps
// =============================================================================
// Pre-silicon check of the Blackboard hardware test (axi4_xbar_hw_top)
// =============================================================================
// Drives the board switches/button exactly as you would by hand:
//   run 1: RUN + STALL + DECERR, then stop -> expect PASS and control check OK
//   run 2: RUN only (no stalls) -> report throughput, then stop -> expect PASS
// Protocol checkers watch both master ports and all three slave ports
// (compile with +define+AXI_HW_SIM).
// =============================================================================
module tb_hw_top;

    logic        clk = 0;
    logic [3:0]  btn = 4'b0001;
    logic [11:0] sw  = '0;
    logic [9:0]  led;
    logic [2:0]  rgb_a, rgb_b;
    logic [3:0]  seg_an;
    logic [7:0]  seg_cat;

    always #5 clk = ~clk;

    axi4_xbar_hw_top #(.WIN_LOG2(14)) dut (
        .clk(clk), .btn(btn), .sw(sw), .led(led),
        .RGB_led_A(rgb_a), .RGB_led_B(rgb_b), .seg_an(seg_an), .seg_cat(seg_cat));

    // Protocol checkers are instantiated inside the DUT under `ifdef AXI_HW_SIM
    // (hierarchical interface references cannot be passed to ports).

    int errors = 0;

    task automatic one_run(string name, bit stall, bit decerr, int cycles);
        repeat (5) @(posedge clk);
        #1 sw[1] = stall; sw[2] = decerr; sw[0] = 1;
        repeat (cycles) @(posedge clk);
        $display("  %-28s throughput x1000: M0=%0d M1=%0d total=%0d",
                 name, dut.per_mille(dut.thr0), dut.per_mille(dut.thr1),
                 dut.per_mille(dut.thr0) + dut.per_mille(dut.thr1));
        #1 sw[0] = 0;
        // Wait for the control-plane check (timeout after 200k cycles)
        for (int t = 0; t < 200000 && !dut.ctrl_checked; t++) @(posedge clk);
        repeat (5) @(posedge clk);
        $display("  %-28s txns=%0d decerr=%0d errs=%0d ctrl_checked=%0b ctrl_bad=%0b route_err=%b PASS_LED=%0b",
                 name, dut.txn_total, dut.decerr_total, dut.err_total,
                 dut.ctrl_checked, dut.ctrl_bad, dut.route_err, led[1]);
        if (!led[1]) begin
            $display("[%0t] ERROR %s: PASS LED not lit (led=%b)", $time, name, led);
            errors++;
        end
        if (decerr && dut.decerr_total == 0) begin
            $display("[%0t] ERROR %s: DECERR mode produced no DECERRs", $time, name);
            errors++;
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        #1 btn[0] = 0;
        repeat (10) @(posedge clk);

        $display("=== Blackboard hardware-test pre-silicon simulation ===");
        one_run("stall+decerr", 1, 1, 300000);
        one_run("full speed",   0, 0, 300000);

        dut.c_m0.final_check(); dut.c_m1.final_check();
        dut.c_s0.final_check(); dut.c_s1.final_check(); dut.c_s2.final_check();
        errors += dut.c_m0.errors + dut.c_m1.errors + dut.c_s0.errors + dut.c_s1.errors + dut.c_s2.errors;

        if (errors == 0) $display("*** PASS tb_hw_top ***");
        else             $display("*** FAIL tb_hw_top: %0d errors ***", errors);
        $finish;
    end

endmodule
