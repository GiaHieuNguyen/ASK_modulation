`timescale 1ns / 1ps

module dds_sine #(
    parameter int PHASE_W = 32,    // Width of Phase Accumulator
    parameter int LUT_ADDR_W = 10, // Top 10 bits used for ROM address
    parameter int AMP_W = 16,      // 16-bit output
    parameter string SINE_MEM_FILE = "carrier_sine.mem"
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic [PHASE_W-1:0] phase_inc, // Tuning word controls frequency
    output logic signed [AMP_W-1:0] sine_out
);

    // Phase Accumulator Register
    logic [PHASE_W-1:0] phase_acc;
    
    // ROM Array definition
    logic signed [AMP_W-1:0] sine_rom [0:(2**LUT_ADDR_W)-1];

    // Load the ROM from the Python-generated file
    // Vivado will synthesize this directly into a Block RAM (BRAM)
    initial begin
        $readmemh(SINE_MEM_FILE, sine_rom);
    end

    // Accumulator Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= '0;
        end else begin
            phase_acc <= phase_acc + phase_inc;
        end
    end

    // ROM Read (Pipelined for high fmax)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sine_out <= '0;
        end else begin
            // Use the top LUT_ADDR_W bits of the accumulator to address the ROM
            sine_out <= sine_rom[phase_acc[PHASE_W-1 : PHASE_W-LUT_ADDR_W]];
        end
    end

endmodule
