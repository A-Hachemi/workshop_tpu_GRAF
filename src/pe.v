// Processing Element of Systolic Array

`define DATA_WIDTH 8  // Define bit-width for input A and B
`define ACC_WIDTH 8  // Define bit-width for accumulation C

module pe (
    input  wire clk,
    input  wire rst_n,
    input  wire we,  // Write enable signal
    input  wire [`DATA_WIDTH-1:0] a_in,     // Input A from the left
    input  wire [`DATA_WIDTH-1:0] b_in,     // Input B from the top
    output wire [`DATA_WIDTH-1:0] a_out,    // Pass A to the right
    output wire [`DATA_WIDTH-1:0] b_out,    // Pass B to the bottom
    output wire [`ACC_WIDTH-1:0]  c_out     // Accumulated result
);

    // Internal registers to store current A and B values
    reg [`ACC_WIDTH*2-1:0]  c_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin           // Reset
            c_reg <= 0;             // Reset accumulation register
        end else if (we) begin      // Update only when we = 1

            c_reg <= c_reg + a_in * b_in;  // Perform multiply-accumulate operation
        end
    end

    // Pass values
    assign a_out = a_in;
    assign b_out = b_in;
    // Output
    assign c_out = c_reg;

endmodule
