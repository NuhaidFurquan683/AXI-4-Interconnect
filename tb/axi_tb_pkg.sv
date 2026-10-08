`timescale 1ns/1ps
// =============================================================================
// Shared testbench types and helpers
// =============================================================================
package axi_tb_pkg;

    localparam int TB_ADDR_W = 32;
    localparam int TB_DATA_W = 32;
    localparam int TB_ID_W   = 4;
    localparam int TB_STRB_W = TB_DATA_W / 8;

    localparam logic [1:0] BURST_FIXED = 2'b00;
    localparam logic [1:0] BURST_INCR  = 2'b01;
    localparam logic [1:0] BURST_WRAP  = 2'b10;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // One AXI4 transaction: stimulus fields + collected response fields
    class axi_txn;
        bit                   is_write;
        logic [TB_ID_W-1:0]   id;
        logic [TB_ADDR_W-1:0] addr;
        logic [7:0]           len;
        logic [2:0]           size;
        logic [1:0]           burst;
        logic [TB_DATA_W-1:0] wdata [$];
        logic [TB_STRB_W-1:0] wstrb [$];

        // Response
        logic [TB_ID_W-1:0]   rsp_id;
        logic [1:0]           bresp;
        logic [TB_DATA_W-1:0] rdata [$];
        logic [1:0]           rresp [$];
        bit                   done;
        longint               t_start, t_end;

        function new();
            size  = 3'd2;      // 4 bytes = full 32-bit bus
            burst = BURST_INCR;
            done  = 0;
        endfunction
    endclass

    // AXI4 address of beat n (spec A3.4.1), full-width transfers
    function automatic logic [TB_ADDR_W-1:0] beat_addr(
        logic [TB_ADDR_W-1:0] start, logic [2:0] size, logic [7:0] len,
        logic [1:0] burst, int n);
        int unsigned nbytes = 1 << size;
        int unsigned wrap_sz;
        logic [TB_ADDR_W-1:0] aligned, lower, a;
        aligned = (start / nbytes) * nbytes;
        case (burst)
            BURST_FIXED: return start;
            BURST_WRAP: begin
                wrap_sz = nbytes * (int'(len) + 1);
                lower   = (start / wrap_sz) * wrap_sz;
                a       = start + TB_ADDR_W'(n * nbytes);
                if (a >= lower + wrap_sz) a = a - wrap_sz;
                return a;
            end
            default: return (n == 0) ? start : aligned + TB_ADDR_W'(n * nbytes);
        endcase
    endfunction

endpackage
