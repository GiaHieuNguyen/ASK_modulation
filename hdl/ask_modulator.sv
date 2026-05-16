`timescale 1ns / 1ps

module ask_modulator #(
    parameter int PHASE_W = 32,
    parameter int LUT_ADDR_W = 10,
    parameter int AMP_W = 16,
    parameter int MULT_W = 8,
    parameter int AXI_ADDR_W = 12,
    parameter int IFM_ADDR_W = 12,
    parameter string SINE_MEM_FILE = "carrier_sine.mem",
    parameter logic [31:0] DEFAULT_PHASE_INC = 32'd42949673,
    parameter logic [31:0] DEFAULT_SYMBOL_HOLD_CYCLES = 32'd1000,
    parameter logic [31:0] DEFAULT_SYMBOL_COUNT = 32'd1024
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

    output logic signed [AMP_W-1:0] ask_out,
    output logic signed [AMP_W-1:0] carrier_dbg,
    output logic [AMP_W-1:0]        dac_data,
    output logic [1:0]              symbol_dbg,
    output logic                    symbol_valid_dbg
);

    localparam longint unsigned SCALE_MAX = (64'd1 << MULT_W) - 1;
    localparam logic [MULT_W-1:0] SCALE_0 = '0;
    localparam logic [MULT_W-1:0] SCALE_1 = SCALE_MAX / 3;
    localparam logic [MULT_W-1:0] SCALE_2 = (SCALE_MAX * 2) / 3;
    localparam logic [MULT_W-1:0] SCALE_3 = SCALE_MAX;

    logic enable_ctrl;
    logic loop_enable_ctrl;
    logic soft_reset_pulse;
    logic start_pulse;
    logic [31:0] phase_inc_reg;
    logic [31:0] symbol_hold_cycles_reg;
    logic [31:0] symbol_count_reg;

    logic player_busy;
    logic player_done;
    logic [31:0] current_symbol_index;
    logic [1:0] active_symbol;
    logic active_symbol_valid;

    logic datapath_rst_n;
    logic signed [AMP_W-1:0] carrier_int;
    logic signed [AMP_W-1:0] ask_int;
    logic [MULT_W-1:0] active_scale;

    logic [31:0] status_current_symbol;
    logic [31:0] status_current_scale;
    logic [31:0] status_current_carrier;
    logic [31:0] status_current_ask;

    assign datapath_rst_n = s_axi_aresetn && enable_ctrl && !soft_reset_pulse;

    axi_slave #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_DATA_W(32),
        .DEFAULT_PHASE_INC(DEFAULT_PHASE_INC),
        .DEFAULT_SYMBOL_HOLD_CYCLES(DEFAULT_SYMBOL_HOLD_CYCLES),
        .DEFAULT_SYMBOL_COUNT(DEFAULT_SYMBOL_COUNT)
    ) u_axi_slave (
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
        .enable(enable_ctrl),
        .loop_enable(loop_enable_ctrl),
        .soft_reset_pulse(soft_reset_pulse),
        .start_pulse(start_pulse),
        .phase_inc(phase_inc_reg),
        .symbol_hold_cycles(symbol_hold_cycles_reg),
        .symbol_count(symbol_count_reg),
        .status_player_busy(player_busy),
        .status_player_done(player_done),
        .current_symbol(status_current_symbol),
        .current_symbol_index(current_symbol_index),
        .current_carrier(status_current_carrier),
        .current_ask_out(status_current_ask)
    );

    symbol_bram_player #(
        .IFM_ADDR_W(IFM_ADDR_W)
    ) u_symbol_player (
        .clk(s_axi_aclk),
        .rst_n(datapath_rst_n),
        .enable(enable_ctrl),
        .start(start_pulse),
        .loop_enable(loop_enable_ctrl),
        .symbol_count(symbol_count_reg),
        .symbol_hold_cycles(symbol_hold_cycles_reg),
        .ifm_bram_rdata(ifm_bram_rdata),
        .ifm_bram_en(ifm_bram_en),
        .ifm_bram_addr(ifm_bram_addr),
        .symbol_out(active_symbol),
        .symbol_valid(active_symbol_valid),
        .busy(player_busy),
        .done(player_done),
        .current_symbol_index(current_symbol_index)
    );

    dds_sine #(
        .PHASE_W(PHASE_W),
        .LUT_ADDR_W(LUT_ADDR_W),
        .AMP_W(AMP_W),
        .SINE_MEM_FILE(SINE_MEM_FILE)
    ) u_dds (
        .clk(s_axi_aclk),
        .rst_n(datapath_rst_n),
        .phase_inc(phase_inc_reg[PHASE_W-1:0]),
        .sine_out(carrier_int)
    );

    mary_ask_modulator #(
        .AMP_W(AMP_W),
        .MULT_W(MULT_W)
    ) u_modulator (
        .clk(s_axi_aclk),
        .rst_n(datapath_rst_n),
        .symbol_in(active_symbol),
        .carrier_in(carrier_int),
        .mask_out(ask_int)
    );

    function automatic logic [MULT_W-1:0] symbol_to_scale(input logic [1:0] symbol);
        begin
            case (symbol)
                2'b00: symbol_to_scale = SCALE_0;
                2'b01: symbol_to_scale = SCALE_1;
                2'b11: symbol_to_scale = SCALE_2;
                2'b10: symbol_to_scale = SCALE_3;
                default: symbol_to_scale = SCALE_0;
            endcase
        end
    endfunction

    assign active_scale = symbol_to_scale(active_symbol);
    assign ask_out = (enable_ctrl && active_symbol_valid) ? ask_int : '0;
    assign carrier_dbg = enable_ctrl ? carrier_int : '0;
    assign symbol_dbg = active_symbol;
    assign symbol_valid_dbg = active_symbol_valid;
    assign dac_data = ask_out ^ {1'b1, {(AMP_W-1){1'b0}}};

    assign status_current_symbol = {30'b0, active_symbol};
    assign status_current_scale = {{(32-MULT_W){1'b0}}, active_scale};
    assign status_current_carrier = {{(32-AMP_W){carrier_dbg[AMP_W-1]}}, carrier_dbg};
    assign status_current_ask = {{(32-AMP_W){ask_out[AMP_W-1]}}, ask_out};

    logic unused_status_scale;
    assign unused_status_scale = ^status_current_scale;

endmodule
