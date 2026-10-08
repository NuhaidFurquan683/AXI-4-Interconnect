`timescale 1ns/1ps
// =============================================================================
// Unit testbench: round_robin_arbiter
// =============================================================================
// Checks every cycle (random req / done):
//   - grant is one-hot or zero, grant is a subset of req
//   - grant is non-zero whenever req is non-zero (work-conserving)
//   - the winner is the first requester at or after the priority pointer
//     (reference model in the testbench)
// Fairness: with all requesters active and done every cycle, every requester
// is granted exactly once per NUM_REQ cycles.
// =============================================================================
module tb_round_robin_arbiter;

    localparam int N = 4;

    logic         clk = 0, rst_n = 0;
    logic [N-1:0] req = '0;
    logic         done = 0;
    logic [N-1:0] grant;

    always #5 clk = ~clk;

    round_robin_arbiter #(.NUM_REQ(N)) dut (.*);

    int errors = 0;
    int ptr_model = 0;        // reference priority pointer
    int grants [N];

    function automatic void fail(string msg);
        $display("[%0t] ERROR %s", $time, msg);
        errors++;
    endfunction

    function automatic int ref_winner(logic [N-1:0] r, int p);
        for (int i = 0; i < N; i++)
            if (r[(p + i) % N]) return (p + i) % N;
        return -1;
    endfunction

    always @(negedge clk) begin
        if (rst_n) begin
            int w;
            w = ref_winner(req, ptr_model);
            if ((grant & ~req) != 0)        fail($sformatf("grant %b not subset of req %b", grant, req));
            if ($countones(grant) > 1)      fail($sformatf("grant %b not one-hot", grant));
            if (req != 0 && grant == 0)     fail("requests pending but no grant");
            if (w >= 0 && grant != (N'(1) << w))
                fail($sformatf("req %b ptr %0d: grant %b, expected winner %0d", req, ptr_model, grant, w));
            if (w >= 0) grants[w]++;
            if (done && w >= 0) ptr_model = (w + 1) % N;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        #1 rst_n = 1;

        // Random traffic
        repeat (5000) begin
            @(posedge clk); #1;
            req  = N'($urandom);
            done = ($urandom_range(0, 1) == 1) && (req != 0);
        end

        // Fairness: everyone requests, done every cycle
        @(posedge clk); #1;
        req = '1; done = 1;
        @(posedge clk); #1;
        foreach (grants[i]) grants[i] = 0;
        repeat (N * 100) @(posedge clk);
        #1;
        foreach (grants[i])
            if (grants[i] != 100) fail($sformatf("requester %0d granted %0d/100 times", i, grants[i]));

        if (errors == 0) $display("*** PASS tb_round_robin_arbiter ***");
        else             $display("*** FAIL tb_round_robin_arbiter: %0d errors ***", errors);
        $finish;
    end

endmodule
