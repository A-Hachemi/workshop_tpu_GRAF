
// 4x4 Systolic Array

`define DATA_WIDTH 8
`define ACC_WIDTH  16  // Must match pe.v

module array (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         we,
    input  wire [`DATA_WIDTH*4-1:0]     a_in,     // 4 activation rows
    input  wire [`DATA_WIDTH*4-1:0]     b_in,     // 4 weight columns
    output wire [`ACC_WIDTH*16-1:0]     data_out  // 16 accumulated results, each ACC_WIDTH wide
);

    wire [`DATA_WIDTH-1:0] a_pipe [0:3][0:4];
    wire [`DATA_WIDTH-1:0] b_pipe [0:4][0:3];
    wire [`ACC_WIDTH-1:0]  c_bus  [0:3][0:3];

    genvar row, col;
    generate
        for (row = 0; row < 4; row = row + 1)
            assign a_pipe[row][0] = a_in[`DATA_WIDTH*(row+1)-1:`DATA_WIDTH*row];
        for (col = 0; col < 4; col = col + 1)
            assign b_pipe[0][col] = b_in[`DATA_WIDTH*(col+1)-1:`DATA_WIDTH*col];
    endgenerate

    generate
        for (genvar r = 0; r < 4; r = r + 1) begin : ROWS
            for (genvar c = 0; c < 4; c = c + 1) begin : COLS
                pe pe_inst (
                    .clk   (clk),
                    .rst_n (rst_n),
                    .we    (we),
                    .a_in  (a_pipe[r][c]),
                    .b_in  (b_pipe[r][c]),
                    .a_out (a_pipe[r][c+1]),
                    .b_out (b_pipe[r+1][c]),
                    .c_out (c_bus [r][c])
                );
            end
        end
    endgenerate

    generate
        for (genvar r = 0; r < 4; r = r + 1)
            for (genvar c = 0; c < 4; c = c + 1) begin
                localparam idx = r*4 + c;
                assign data_out[`ACC_WIDTH*(idx+1)-1:`ACC_WIDTH*idx] = c_bus[r][c];
            end
    endgenerate

endmodule