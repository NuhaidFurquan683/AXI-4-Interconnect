module skid_buffer #(
  parameter int DATA_WIDTH = 32
)(
  input logic clk,
  input logic rst_n,
  input logic in_valid, 
  input logic [DATA_WIDTH-1:0] in_data,
  input logic out_ready,
  output logic in_ready,
  output logic out_valid, 
  output logic [DATA_WIDTH-1:0] out_data
  );

  typedef enum logic [1:0] {
      EMPTY,
      BUSY,
      FULL
    } state_t;

    state_t current_state, next_state;

  logic [DATA_WIDTH-1 : 0] main_reg;
  logic [DATA_WIDTH-1 : 0] skid_reg;

  assign out_data = main_reg;

  always_ff @(posedge clk, negedge rst_n) begin 

      if (!rst_n) 
          current_state <= EMPTY;
      else 
          current_state <= next_state;

  end 
  
  always_ff @(posedge clk, negedge rst_n) begin

       if (!rst_n) begin
        main_reg <= '0;
        skid_reg <= '0;
        end

      else if (current_state == EMPTY && (in_valid)) 
          main_reg <= in_data;

      else if (current_state == BUSY && (in_valid && out_ready)) 
          main_reg <= in_data;

      else if (current_state == BUSY && (in_valid && !out_ready))
          skid_reg <= in_data;

      else if (current_state == FULL && (out_ready))
          main_reg <= skid_reg;

  end

  always_comb begin

      next_state = current_state; 
      
      case(current_state) 
          
          EMPTY: begin
              if (in_valid) 
                  next_state = BUSY;
              end

          BUSY : begin
              if (in_valid && out_ready) 
                  next_state = BUSY;
              else if (in_valid && !out_ready) 
                  next_state = FULL;
              else if (!in_valid && out_ready) 
                  next_state = EMPTY;
              else 
                  next_state = BUSY;
          end 

          FULL : begin
              if (!out_ready) 
                  next_state = FULL;
              else 
                  next_state = BUSY;
          end 

          default : next_state = EMPTY;
      endcase
  end

  assign in_ready = (current_state != FULL);
  assign out_valid = (current_state != EMPTY);

endmodule

