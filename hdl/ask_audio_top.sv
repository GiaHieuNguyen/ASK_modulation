`timescale 1ns / 1ps

module ask_audio_top #(
    parameter int PHASE_W = 32,
    parameter int LUT_ADDR_W = 10,
    parameter int AMP_W = 16,
    parameter int MULT_W = 8,
    parameter int AXI_ADDR_W = 12,
    parameter int IFM_ADDR_W = 12,
    parameter int AUDIO_SHIFT = 2,
    parameter string SINE_MEM_FILE = "carrier_sine.mem",
    parameter logic [31:0] DEFAULT_PHASE_INC = 32'd171799,
    parameter logic [31:0] DEFAULT_SYMBOL_HOLD_CYCLES = 32'd1000000,
    parameter logic [31:0] DEFAULT_SYMBOL_COUNT = 32'd4096
)(
    input  logic                    s_axi_aclk,
    input  logic                    s_axi_aresetn,

    input  logic [AXI_ADDR_W-1:0]   s_axi_awaddr,
    input  logic [2:0]              s_axi_awprot,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    input  logic [31:0]             s_axi_wdata,
    input  logic [3:0]              s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [AXI_ADDR_W-1:0]   s_axi_araddr,
    input  logic [2:0]              s_axi_arprot,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    output logic [31:0]             s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    input  logic [31:0]             ifm_bram_rdata,
    output logic                    ifm_bram_en,
    output logic [IFM_ADDR_W-1:0]   ifm_bram_addr,

    output logic                    codec_mclk,
    output logic                    codec_bclk,
    output logic                    codec_lrclk,
    output logic                    codec_sdata_o,

    output logic signed [AMP_W-1:0] ask_out_dbg,
    output logic signed [AMP_W-1:0] carrier_dbg,
    output logic [1:0]              symbol_dbg,
    output logic                    symbol_valid_dbg
);

    logic signed [AMP_W-1:0] ask_out_int;
    logic [AMP_W-1:0] dac_data_unused;
    logic signed [AMP_W-1:0] audio_sample;

    ask_modulator #(
        .PHASE_W(PHASE_W),
        .LUT_ADDR_W(LUT_ADDR_W),
        .AMP_W(AMP_W),
        .MULT_W(MULT_W),
        .AXI_ADDR_W(AXI_ADDR_W),
        .IFM_ADDR_W(IFM_ADDR_W),
        .SINE_MEM_FILE(SINE_MEM_FILE),
        .DEFAULT_PHASE_INC(DEFAULT_PHASE_INC),
        .DEFAULT_SYMBOL_HOLD_CYCLES(DEFAULT_SYMBOL_HOLD_CYCLES),
        .DEFAULT_SYMBOL_COUNT(DEFAULT_SYMBOL_COUNT)
    ) u_ask_modulator (
        .s_axi_aclk(s_axi_aclk),
        .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .ifm_bram_rdata(ifm_bram_rdata),
        .ifm_bram_en(ifm_bram_en),
        .ifm_bram_addr(ifm_bram_addr),
        .ask_out(ask_out_int),
        .carrier_dbg(carrier_dbg),
        .dac_data(dac_data_unused),
        .symbol_dbg(symbol_dbg),
        .symbol_valid_dbg(symbol_valid_dbg)
    );

    always_comb begin
        if (AUDIO_SHIFT <= 0) begin
            audio_sample = ask_out_int;
        end else begin
            audio_sample = ask_out_int >>> AUDIO_SHIFT;
        end
    end

    audio_i2s_tx #(
        .SAMPLE_W(AMP_W),
        .AUDIO_W(24),
        .SLOT_W(32),
        .MCLK_HALF_CYCLES(5),
        .BCLK_HALF_CYCLES(16)
    ) u_audio_i2s_tx (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .sample_in(audio_sample),
        .sample_valid(symbol_valid_dbg),
        .codec_mclk(codec_mclk),
        .codec_bclk(codec_bclk),
        .codec_lrclk(codec_lrclk),
        .codec_sdata_o(codec_sdata_o)
    );

    assign ask_out_dbg = ask_out_int;

    logic unused_dac_data;
    assign unused_dac_data = ^dac_data_unused;

endmodule
