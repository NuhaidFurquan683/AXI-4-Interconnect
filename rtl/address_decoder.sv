module address_decoder #(
    parameter ADDR_WIDTH = 32,
    parameter NUM_SLAVES = 4
  )(
      /* verilator lint_off UNUSEDSIGNAL */
      input logic [ADDR_WIDTH -1 : 0] addr, //Input address required for the transaction, will decide what slave to use to complete the transaction 
      /* verilator lint_off UNUSEDSIGNAL */
      output logic error,  //Later on becomes the basis for the crossbar's DECERR signal
      output logic [$clog2(NUM_SLAVES) -1 : 0] slave_select //Output indicating which slave to use to access that particular addressing range in memory
    );

  assign slave_select = addr[ADDR_WIDTH -1 : (ADDR_WIDTH - $clog2(NUM_SLAVES))]; //Just taking the top bits of the address to assign a slave
  /* verilator lint_off UNSIGNED */
  assign error = (slave_select >= ($clog2(NUM_SLAVES))'(NUM_SLAVES));  //Error assertion, when data address goes out of range
  /* verilator lint_on UNSIGNED */
  endmodule 
// The slave_select logic is simple, just check the top bits needed to
// represent the count up to NUM_SLAVES and whatever address starts with that
// will be assigned to that particular slave. Co-incidentally this creates an
// equal division between the total amount of space (4GB) in memory that we
// can address between all the slaves. 
