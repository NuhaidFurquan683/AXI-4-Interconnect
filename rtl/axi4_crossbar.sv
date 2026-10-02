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

    logic [NUM_MASTERS-1:0] aw_req [NUM_SLAVES];
        
    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin 
            aw_req[j] = '0; 
            for (int k = 0; k < NUM_MASTERS; k++) begin
                if (aw_slave_select[k] == j && master_ports[k].awvalid)
                    aw_req[j][k] = 1;
            end           
        end
    end 

    logic [NUM_MASTERS-1 : 0] aw_grant [NUM_SLAVES];
    logic aw_done [NUM_SLAVES];
    logic [$clog2(NUM_MASTERS)-1 : 0] aw_winner [NUM_SLAVES];

    generate
        for (i = 0; i < NUM_SLAVES; i++) begin : gen_arbiters
            round_robin_arbiter #(
                .NUM_REQ(NUM_MASTERS)
                ) u_arbiter (
                .clk(clk), 
                .rst_n(rst_n),
                .req(aw_req[i]),
                .grant(aw_grant[i]),
                .done(aw_done[i])
                    );
        end 
    endgenerate

    always_comb begin
        for (int j = 0; j < NUM_SLAVES; j++) begin 
            aw_winner[j] = '0;
            for (int k = 0; k < NUM_MASTERS; k++) begin 
                if (aw_grant[j][k] == 1) 
                    aw_winner[j] = k[$clog2(NUM_MASTERS)-1:0];
            end 
        end 
    end
    
    generate 
        for (i = 0; i < NUM_SLAVES; i++) begin : gen_ids
            assign slave_ports[i].awaddr = master_ports[aw_winner[i]].awaddr;
            assign slave_ports[i].awlen = master_ports[aw_winner[i]].awlen;
            assign slave_ports[i].awsize = master_ports[aw_winner[i]].awsize;
            assign slave_ports[i].awburst = master_ports[aw_winner[i]].awburst;
            assign slave_ports[i].awvalid = master_ports[aw_winner[i]].awvalid; 
            assign slave_ports[i].awid = {aw_winner[i], master_ports[aw_winner[i]].awid};
        end
    endgenerate

    always_comb begin 
        for (int i = 0; i < NUM_MASTERS; i++) begin 
            master_ports[i].awready = 0; 
            if (!aw_decode_error[i] && aw_grant[aw_slave_select[i]][i] && slave_ports[aw_slave_select[i]].awready) 
                master_ports[i].awready = 1;
        end 
    end 

endmodule 

