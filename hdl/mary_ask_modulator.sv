`timescale 1ns / 1ps

module mary_ask_modulator #(
    parameter int AMP_W = 16,        // 16-bit Carrier
    parameter int MULT_W = 8         // 8-bit amplitude scaling factor
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic [1:0]         symbol_in,   // 2 bits per symbol (4-ASK)
    input  logic signed [AMP_W-1:0] carrier_in,  
    output logic signed [AMP_W-1:0] mask_out     // Final modulated output
);

    // Stage 1: Symbol Mapper (Creates the amplitude scaling factor)
    logic unsigned [MULT_W-1:0] amplitude_scale;

    localparam longint unsigned SCALE_MAX = (64'd1 << MULT_W) - 1;
    localparam logic [MULT_W-1:0] SCALE_0 = '0;
    localparam logic [MULT_W-1:0] SCALE_1 = SCALE_MAX / 3;
    localparam logic [MULT_W-1:0] SCALE_2 = (SCALE_MAX * 2) / 3;
    localparam logic [MULT_W-1:0] SCALE_3 = SCALE_MAX;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amplitude_scale <= '0;
        end else begin
            // Map 2 bits to 4 levels (e.g., 0%, 33%, 66%, 100% of max amplitude)
            case (symbol_in)
                2'b00: amplitude_scale <= SCALE_0; // Level 0
                2'b01: amplitude_scale <= SCALE_1; // Level 1 (~33%)
                2'b11: amplitude_scale <= SCALE_2; // Level 2 (~66%)
                2'b10: amplitude_scale <= SCALE_3; // Level 3 (100%)
                default: amplitude_scale <= SCALE_0;
            endcase
        end
    end

    // Stage 2: The Modulator (Multiplier)
    // signed_scale is MULT_W+1 bits, so the full product is AMP_W+MULT_W+1 bits.
    logic signed [AMP_W+MULT_W:0] full_mult_out;

    // We must treat the unsigned amplitude scale as a signed positive number
    // to multiply correctly with the signed carrier wave.
    logic signed [MULT_W:0] signed_scale;
    assign signed_scale = {1'b0, amplitude_scale};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full_mult_out <= '0;
            mask_out      <= '0;
        end else begin
            full_mult_out <= carrier_in * signed_scale;
            
            // Normalize back to 16-bit. 
            // We shift right by 8 (because our max scale was 255, roughly 2^8)
            mask_out <= full_mult_out >>> MULT_W;
        end
    end

endmodule
