module top_ask #(
    parameter int PHASE_W    = 32,
    parameter int LUT_ADDR_W = 10,
    parameter int AMP_W      = 16,
    parameter int MULT_W     = 8,
    parameter logic [PHASE_W-1:0] PHASE_INC = 32'd42949673, // 1 MHz @ 100 MHz clk
    parameter string SINE_MEM_FILE = "../tb/carrier_sine.mem"
)(
    input  logic clk,
    input  logic rst_n,
    input  logic [1:0] symbol_in,
    output logic signed [AMP_W-1:0] carrier_dbg,
    output logic signed [AMP_W-1:0] ask_out
);

    logic signed [AMP_W-1:0] carrier;

    dds_sine #(
        .PHASE_W(PHASE_W),
        .LUT_ADDR_W(LUT_ADDR_W),
        .AMP_W(AMP_W),
        .SINE_MEM_FILE(SINE_MEM_FILE)
    ) u_dds (
        .clk(clk),
        .rst_n(rst_n),
        .phase_inc(PHASE_INC),
        .sine_out(carrier)
    );

    mary_ask_modulator #(
        .AMP_W(AMP_W),
        .MULT_W(MULT_W)
    ) u_mod (
        .clk(clk),
        .rst_n(rst_n),
        .symbol_in(symbol_in),
        .carrier_in(carrier),
        .mask_out(ask_out)
    );

    assign carrier_dbg = carrier;

endmodule
