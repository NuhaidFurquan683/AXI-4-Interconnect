interface axi4_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH = 4
  );
    
    localparam int STRB_WIDTH = DATA_WIDTH/8; //Strobe width derived form a 32-bit data width allowing for 4 distinct byte channels
    
    logic aresetn;
    logic aclk;
    
    // Write address channel 
    logic [ID_WIDTH - 1 : 0] awid;
    logic [ADDR_WIDTH - 1 : 0] awaddr;
    logic [7:0] awlen; //Burst length (0-255), actual length = awlen + 1
    logic [2:0] awsize; //Bytes per transfer
    logic [1:0] awburst; //FIXED = 00, INCR = 01, WRAP = 10
    logic awvalid;
    logic awready; 


    // Write data channel 
    logic [DATA_WIDTH - 1 : 0] wdata;
    logic [STRB_WIDTH -1 : 0] wstrb;
    logic wlast;
    logic wvalid;
    logic wready;


    // Write response channel
    logic [ID_WIDTH -1 : 0] bid;
    logic [1:0] bresp; //00 = OKAY, 01 = EXOKAY, 10 = SLVERR, 11 = DECERR
    logic bvalid;
    logic bready;

    // Read address channel
    logic [ID_WIDTH -1 : 0] arid; 
    logic [ADDR_WIDTH -1 : 0] araddr; 
    logic [7:0] arlen; 
    logic [2:0] arsize;
    logic [1:0] arburst;
    logic arvalid;
    logic arready;

    // Read data channel
    logic [ID_WIDTH - 1 : 0] rid; 
    logic [DATA_WIDTH -1 : 0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    logic rready;

    //Respective master-slave modports
modport master (
    // AW 
    output awid, awvalid, awaddr, awlen, awsize, awburst,
    input awready,

    //W
    output wdata, wvalid, wstrb, wlast, 
    input wready, 

    //B 
    input bid, bresp, bvalid,
    output bready, 

    //AR  
    output arid, arvalid, araddr, arlen, arsize, arburst,
    input arready,

    //R
    input rdata,rlast, rresp, rid, rvalid, 
    output rready
    );

modport slave (
    // AW
    input  awid, awaddr, awlen, awsize, awburst, awvalid,
    output awready,

    // W
    input  wdata, wstrb, wlast, wvalid,
    output wready,

    // B
    output bid, bresp, bvalid,
    input  bready,

    // AR
    input  arid, araddr, arlen, arsize, arburst, arvalid,
    output arready,

    // R
    output rid, rdata, rresp, rlast, rvalid,
    input  rready
  ); 
endinterface
