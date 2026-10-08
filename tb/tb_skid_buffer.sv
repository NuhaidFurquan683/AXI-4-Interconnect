`timescale 1ns/1ps
// =============================================================================
// Unit testbench: skid_buffer (register slice)
// =============================================================================
// Random in_valid / out_ready with three stall profiles. Checks:
//   - every word comes out exactly once, in order (scoreboard queue)
//   - out_valid / out_data stay stable while out_ready is low
//   - in_ready and out_valid are registered (no combinational path from
//     out_ready / in_valid) — verified by changing the inputs mid-cycle
//   - full throughput (1 word/cycle) when out_ready is held high
// =============================================================================
module tb_skid_buffer;

    localparam int W = 16;

    logic         clk = 0, rst_n = 0;
    logic         in_valid = 0, out_ready = 0;
    logic [W-1:0] in_data = '0;
    logic         in_ready, out_valid;
    logic [W-1:0] out_data;

    always #5 clk = ~clk;

    skid_buffer #(.DATA_WIDTH(W)) dut (.*);

    logic [W-1:0] exp_q [$];
    int errors = 0, sent = 0, recvd = 0;
    int in_pct = 50, out_pct = 50;

    function automatic void fail(string msg);
        $display("[%0t] ERROR %s", $time, msg);
        errors++;
    endfunction

    // Driver: drive 1 ns after rising edge, hold data until accepted
    logic [W-1:0] next_word = '0;
    initial begin
        @(posedge rst_n);
        forever begin
            @(posedge clk); #1;
            // AXI-style source: once valid, hold until accepted
            if (!in_valid || accepted) begin
                in_valid = ($urandom_range(0, 99) < in_pct);
                if (in_valid) in_data = next_word;
            end
            out_ready = ($urandom_range(0, 99) < out_pct);
        end
    end

    // Monitor on the falling edge
    logic accepted = 0;     // in handshake seen at the last falling edge
    logic p_ov = 0, p_or = 0;
    logic [W-1:0] p_od;
    always @(negedge clk) begin
        if (rst_n) begin
            if (in_valid && in_ready) begin
                exp_q.push_back(in_data);
                next_word = next_word + 1;
                sent++;
            end
            if (out_valid && out_ready) begin
                if (exp_q.size() == 0) fail("output with empty scoreboard");
                else begin
                    logic [W-1:0] e;
                    e = exp_q.pop_front();
                    if (out_data != e) fail($sformatf("data %0h, expected %0h", out_data, e));
                end
                recvd++;
            end
            if (p_ov && !p_or && (!out_valid || out_data != p_od))
                fail("output changed while stalled");
        end
        accepted = in_valid && in_ready;
        p_ov <= out_valid; p_or <= out_ready; p_od <= out_data;
    end

    initial begin
        int t0, n0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;

        // Registered-output check: toggling inputs mid-cycle must not
        // change in_ready / out_valid until the next clock edge
        @(posedge clk); #2;
        begin
            logic ir, ov;
            ir = in_ready; ov = out_valid;
            out_ready = ~out_ready; in_valid = ~in_valid; #1;
            if (in_ready != ir || out_valid != ov) fail("in_ready/out_valid are not registered");
            out_ready = ~out_ready; in_valid = ~in_valid;
        end

        for (int p = 0; p < 3; p++) begin
            case (p)
                0: begin in_pct = 50; out_pct = 50; end
                1: begin in_pct = 90; out_pct = 20; end   // mostly full: exercises FULL state
                2: begin in_pct = 20; out_pct = 90; end   // mostly empty
            endcase
            repeat (3000) @(posedge clk);
        end

        // Throughput: both sides always ready
        in_pct = 100; out_pct = 100;
        repeat (20) @(posedge clk);
        t0 = recvd;
        repeat (100) @(posedge clk);
        n0 = recvd - t0;
        if (n0 < 99) fail($sformatf("throughput %0d/100 with no stalls", n0));

        in_pct = 0; out_pct = 100;
        repeat (20) @(posedge clk);
        if (exp_q.size() != 0) fail("words left in buffer after drain");

        if (errors == 0) $display("*** PASS tb_skid_buffer: %0d words, in order, no loss ***", recvd);
        else             $display("*** FAIL tb_skid_buffer: %0d errors ***", errors);
        $finish;
    end

endmodule
