module round_robin_arbiter #(
    parameter int NUM_REQ = 4
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [NUM_REQ-1:0]   req,
    input  logic                 done,
    output logic [NUM_REQ-1:0]   grant
);

    logic [$clog2(NUM_REQ)-1:0] priority_ptr;
    logic [$clog2(NUM_REQ)-1:0] winner;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            priority_ptr <= '0;
        else if (done) 
            priority_ptr <= ($clog2(NUM_REQ))'((32'(winner) + 1) % NUM_REQ);
    end

    logic [$clog2(NUM_REQ)-1:0] index;
    logic found;

    always_comb begin
        grant = '0;
        found = 0;
        winner = '0;
        for (int i = 0; i < NUM_REQ; i++) begin
            index = ($clog2(NUM_REQ))'((32'(priority_ptr) + i) % NUM_REQ);
            if (!found && (req[index])) begin
                grant[index] = 1;
                found = 1;
                winner = index;
            end 
        end       
    end

endmodule
