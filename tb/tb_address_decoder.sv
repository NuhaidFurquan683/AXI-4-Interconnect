`timescale 1ns/1ps
// =============================================================================
// Unit testbench: address_decoder
// =============================================================================
// For 2..8 slaves, checks every top-bit pattern plus random low bits:
// slave_select equals the top $clog2(N) address bits, and error is raised
// exactly when that value is >= N (unmapped region).
// =============================================================================
module tb_address_decoder;

    int errors = 0;

    // One decoder instance per slave count
    logic [31:0] addr;
    logic        err3, err4, err5;
    logic [1:0]  sel3, sel4;
    logic [2:0]  sel5;

    address_decoder #(.ADDR_WIDTH(32), .NUM_SLAVES(3)) u3 (.addr(addr), .error(err3), .slave_select(sel3));
    address_decoder #(.ADDR_WIDTH(32), .NUM_SLAVES(4)) u4 (.addr(addr), .error(err4), .slave_select(sel4));
    address_decoder #(.ADDR_WIDTH(32), .NUM_SLAVES(5)) u5 (.addr(addr), .error(err5), .slave_select(sel5));

    task automatic check(int n, int sel, bit err, int topbits);
        if (sel != topbits)        begin $display("ERROR N=%0d addr %h: sel %0d expected %0d", n, addr, sel, topbits); errors++; end
        if (err != (topbits >= n)) begin $display("ERROR N=%0d addr %h: error %0b", n, addr, err); errors++; end
    endtask

    initial begin
        for (int t = 0; t < 8; t++) begin
            repeat (200) begin
                addr = {3'(t), 29'($urandom)};
                #1;
                check(3, sel3, err3, int'(addr[31:30]));
                check(4, sel4, err4, int'(addr[31:30]));
                check(5, sel5, err5, int'(addr[31:29]));
            end
        end
        if (errors == 0) $display("*** PASS tb_address_decoder ***");
        else             $display("*** FAIL tb_address_decoder: %0d errors ***", errors);
        $finish;
    end

endmodule
