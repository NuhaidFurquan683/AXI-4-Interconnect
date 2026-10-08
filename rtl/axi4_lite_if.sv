`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite Interface
// =============================================================================
// Simplified AXI4 interface for control-plane register access.
// Differences from full AXI4:
//   - No burst support (all transfers are single-beat)
//   - No ID fields
//   - No wlast (always single beat)
//   - Fixed data width (32 or 64 bit)
// =============================================================================

interface axi4_lite_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
);

    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    // Write address channel
    logic [ADDR_WIDTH-1:0] awaddr;
    logic                  awvalid;
    logic                  awready;

    // Write data channel
    logic [DATA_WIDTH-1:0] wdata;
    logic [STRB_WIDTH-1:0] wstrb;
    logic                  wvalid;
    logic                  wready;

    // Write response channel
    logic [1:0] bresp;
    logic       bvalid;
    logic       bready;

    // Read address channel
    logic [ADDR_WIDTH-1:0] araddr;
    logic                  arvalid;
    logic                  arready;

    // Read data channel
    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rvalid;
    logic                  rready;

    modport master (
        output awaddr, awvalid,
        input  awready,

        output wdata, wstrb, wvalid,
        input  wready,

        input  bresp, bvalid,
        output bready,

        output araddr, arvalid,
        input  arready,

        input  rdata, rresp, rvalid,
        output rready
    );

    modport slave (
        input  awaddr, awvalid,
        output awready,

        input  wdata, wstrb, wvalid,
        output wready,

        output bresp, bvalid,
        input  bready,

        input  araddr, arvalid,
        output arready,

        output rdata, rresp, rvalid,
        input  rready
    );

endinterface

