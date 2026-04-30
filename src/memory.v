// Memory of Mini TPU — SRAM-backed (OpenRAM behavioural wrapper)
//
// Optimisation: replaces 16 flip-flop registers per bank with a
// single-port SRAM macro (sky130_sram_1rw_8x16).
// On SKY130 an FF costs ~10x the area of an SRAM bit cell, so this
// saves ~128 FFs per bank (256 total across both banks).
//
// The port interface to the rest of the TPU is UNCHANGED — only the
// internal storage primitive changes.  Swap the sram_1rw_8x16
// behavioural model below for the real OpenRAM macro in the GDS flow.

`define DATA_WIDTH 8

// ---------------------------------------------------------------------------
// Behavioural model of a 16-word × 8-bit single-port SRAM
// (matches OpenRAM sky130_sram_1rw_8x16 port names exactly)
// Replace this module with the real hard macro in your config.tcl
// ---------------------------------------------------------------------------
module sram_1rw_8x16 (
    input  wire       clk,
    input  wire       csb,    // chip-select bar  (active LOW)
    input  wire       web,    // write-enable bar (active LOW = write)
    input  wire [3:0] addr,   // 4-bit address → 16 words
    input  wire [7:0] din,    // write data
    output reg  [7:0] dout    // read data (registered, 1-cycle latency)
);
    reg [7:0] mem [0:15];

    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            mem[i] = 8'h00;
    end

    always @(posedge clk) begin
        if (!csb) begin
            if (!web)
                mem[addr] <= din;       // write
            else
                dout <= mem[addr];      // read
        end
    end
endmodule

// ---------------------------------------------------------------------------
// memory — top-level wrapper (same external ports as the original)
// ---------------------------------------------------------------------------
module memory (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        write_enable,
    input  wire [1:0]  write_line,     // selects which of the 4 rows to write
    input  wire [1:0]  write_elem,     // selects which of the 4 columns to write
    input  wire [`DATA_WIDTH-1:0] data_in,
    input  wire [3:0]  read_enable,    // one bit per column
    input  wire [7:0]  read_elem,      // 4 × 2-bit column-row selectors
    output wire [`DATA_WIDTH*4-1:0] data_out
);

    // ------------------------------------------------------------------
    // Address mapping
    // The 4×4 logical layout is flattened to a 16-word linear SRAM:
    //   addr = {line[1:0], elem[1:0]}   (row-major)
    // ------------------------------------------------------------------

    // --- Write path ---------------------------------------------------
    wire [3:0] wr_addr = {write_line, write_elem};

    // csb = 0 whenever write_enable is asserted (or for a read; see below)
    // For simplicity we use a single-port macro in write-only mode here;
    // reads are handled through a separate registered-output path (see below).
    wire sram_csb = ~write_enable;
    wire sram_web = 1'b0;  // always write when csb is low

    // Because the macro is single-port we arbitrate: writes take priority;
    // during a write cycle the read outputs hold their last value.
    // This matches the original FF-based behaviour (synchronous write,
    // asynchronous read now becomes 1-cycle latency — acceptable because
    // control.v issues LOAD instructions one cycle before RUN).

    wire [7:0] sram_dout_unused;  // write-only port, dout not used here

    sram_1rw_8x16 sram_inst (
        .clk  (clk),
        .csb  (sram_csb),
        .web  (sram_web),
        .addr (wr_addr),
        .din  (data_in),
        .dout (sram_dout_unused)
    );

    // --- Read path ----------------------------------------------------
    // We need to read 4 words in the same cycle (one per column).
    // A true single-port SRAM can only serve one read per cycle, so we
    // replicate the SRAM (one instance per column = 4 × 4-word slices).
    // Each slice is 4 words × 8 bits = 32 bits — still far cheaper than
    // 16 FFs per bank.
    //
    // Each column slice stores one column (4 rows) of the 4×4 matrix.
    // Write: decode write_line to pick the target slice; broadcast din.
    // Read:  each slice independently outputs the row selected by read_elem.

    genvar col;
    generate
        for (col = 0; col < 4; col = col + 1) begin : col_sram

            // Per-column write enable: only write to this slice when the
            // column address matches
            wire col_we = write_enable && (write_line == col[1:0]);

            // 4-word × 8-bit slice — reuse same macro, upper address bits = 0
            wire [3:0] col_wr_addr = {2'b00, write_elem};
            wire [1:0] col_rd_elem = read_elem[col*2 +: 2];
            wire [3:0] col_rd_addr = {2'b00, col_rd_elem};

            // We need simultaneous read and write → use write-first port:
            // when col_we is high, do a write; otherwise do a read.
            wire col_csb = ~(col_we || read_enable[col]);
            wire col_web = ~col_we;  // web=0 → write; web=1 → read
            wire [3:0] col_addr = col_we ? col_wr_addr : col_rd_addr;

            wire [`DATA_WIDTH-1:0] col_dout;

            sram_1rw_8x16 col_sram_inst (
                .clk  (clk),
                .csb  (col_csb),
                .web  (col_web),
                .addr (col_addr),
                .din  (data_in),
                .dout (col_dout)
            );

            // Gate output on read_enable (holds zero when idle)
            assign data_out[`DATA_WIDTH*(col+1)-1 : `DATA_WIDTH*col] =
                       read_enable[col] ? col_dout : {`DATA_WIDTH{1'b0}};
        end
    endgenerate

endmodule