module axi4_crossbar #(
    parameter int NUM_MASTERS = 2,
    parameter int NUM_SLAVES = 3,
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH = 4
)(
    input logic clk,
    input logic rst_n,
    axi4_if.slave  master_ports [NUM_MASTERS],
    axi4_if.master slave_ports  [NUM_SLAVES]
);

    logic [$clog2(NUM_SLAVES)-1:0] aw_slave_select [NUM_MASTERS];
    logic aw_decode_error  [NUM_MASTERS];

    genvar i; 
    generate
        for (i = 0; i < NUM_MASTERS; i++) begin : gen_address_decoders
              address_decoder #(
                  .NUM_SLAVES(NUM_SLAVES),
                  .ADDR_WIDTH(ADDR_WIDTH)
            ) u_address (
                  .error(aw_decode_error[i]),
                  .slave_select(aw_slave_select[i]),
                  .addr(master_ports[i].awaddr)
                 );
        end
    endgenerate
endmodule

