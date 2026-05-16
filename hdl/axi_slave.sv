`timescale 1ns / 1ps

module axi_slave #(
    parameter int AXI_ADDR_W = 12,
    parameter int AXI_DATA_W = 32,
    parameter logic [31:0] DEFAULT_PHASE_INC = 32'd42949673,
    parameter logic [31:0] DEFAULT_SYMBOL_HOLD_CYCLES = 32'd1000,
    parameter logic [31:0] DEFAULT_SYMBOL_COUNT = 32'd1024
)(
    input  logic                      s_axi_aclk,
    input  logic                      s_axi_aresetn,

    input  logic [AXI_ADDR_W-1:0]     s_axi_awaddr,
    input  logic [2:0]                s_axi_awprot,
    input  logic                      s_axi_awvalid,
    output logic                      s_axi_awready,

    input  logic [AXI_DATA_W-1:0]     s_axi_wdata,
    input  logic [(AXI_DATA_W/8)-1:0] s_axi_wstrb,
    input  logic                      s_axi_wvalid,
    output logic                      s_axi_wready,

    output logic [1:0]                s_axi_bresp,
    output logic                      s_axi_bvalid,
    input  logic                      s_axi_bready,

    input  logic [AXI_ADDR_W-1:0]     s_axi_araddr,
    input  logic [2:0]                s_axi_arprot,
    input  logic                      s_axi_arvalid,
    output logic                      s_axi_arready,

    output logic [AXI_DATA_W-1:0]     s_axi_rdata,
    output logic [1:0]                s_axi_rresp,
    output logic                      s_axi_rvalid,
    input  logic                      s_axi_rready,

    output logic                      enable,
    output logic                      loop_enable,
    output logic                      soft_reset_pulse,
    output logic                      start_pulse,
    output logic [31:0]               phase_inc,
    output logic [31:0]               symbol_hold_cycles,
    output logic [31:0]               symbol_count,

    input  logic                      status_player_busy,
    input  logic                      status_player_done,
    input  logic [31:0]               current_symbol,
    input  logic [31:0]               current_symbol_index,
    input  logic [31:0]               current_carrier,
    input  logic [31:0]               current_ask_out
);

    localparam logic [11:0] ADDR_CTRL                 = 12'h000;
    localparam logic [11:0] ADDR_STATUS               = 12'h004;
    localparam logic [11:0] ADDR_PHASE_INC            = 12'h008;
    localparam logic [11:0] ADDR_SYMBOL_HOLD          = 12'h00C;
    localparam logic [11:0] ADDR_SYMBOL_COUNT         = 12'h010;
    localparam logic [11:0] ADDR_CURRENT_SYMBOL       = 12'h014;
    localparam logic [11:0] ADDR_CURRENT_SYMBOL_INDEX = 12'h018;
    localparam logic [11:0] ADDR_CURRENT_CARRIER      = 12'h01C;
    localparam logic [11:0] ADDR_CURRENT_ASK          = 12'h020;

    logic [AXI_ADDR_W-1:0] awaddr_hold;
    logic [AXI_DATA_W-1:0] wdata_hold;
    logic [(AXI_DATA_W/8)-1:0] wstrb_hold;
    logic aw_hold_valid;
    logic w_hold_valid;

    logic [31:0] ctrl_reg;
    logic [11:0] write_addr;
    logic [31:0] write_value;

    assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold_valid && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    assign enable      = ctrl_reg[0];
    assign loop_enable = ctrl_reg[3];

    function automatic logic [31:0] apply_wstrb(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        int byte_idx;
        begin
            merged = old_value;
            for (byte_idx = 0; byte_idx < 4; byte_idx++) begin
                if (strb[byte_idx]) begin
                    merged[(8*byte_idx) +: 8] = new_value[(8*byte_idx) +: 8];
                end
            end
            apply_wstrb = merged;
        end
    endfunction

    function automatic logic [31:0] read_mux(input logic [AXI_ADDR_W-1:0] addr);
        logic [31:0] status_word;
        begin
            status_word = {
                29'b0,
                status_player_done,
                status_player_busy,
                enable
            };

            case (addr[11:0])
                ADDR_CTRL:                 read_mux = ctrl_reg;
                ADDR_STATUS:               read_mux = status_word;
                ADDR_PHASE_INC:            read_mux = phase_inc;
                ADDR_SYMBOL_HOLD:          read_mux = symbol_hold_cycles;
                ADDR_SYMBOL_COUNT:         read_mux = symbol_count;
                ADDR_CURRENT_SYMBOL:       read_mux = current_symbol;
                ADDR_CURRENT_SYMBOL_INDEX: read_mux = current_symbol_index;
                ADDR_CURRENT_CARRIER:      read_mux = current_carrier;
                ADDR_CURRENT_ASK:          read_mux = current_ask_out;
                default:                   read_mux = 32'h0000_0000;
            endcase
        end
    endfunction

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_hold_valid       <= 1'b0;
            w_hold_valid        <= 1'b0;
            awaddr_hold         <= '0;
            wdata_hold          <= '0;
            wstrb_hold          <= '0;
            s_axi_bvalid        <= 1'b0;
            ctrl_reg            <= '0;
            phase_inc           <= DEFAULT_PHASE_INC;
            symbol_hold_cycles  <= DEFAULT_SYMBOL_HOLD_CYCLES;
            symbol_count        <= DEFAULT_SYMBOL_COUNT;
            soft_reset_pulse    <= 1'b0;
            start_pulse         <= 1'b0;
        end else begin
            soft_reset_pulse <= 1'b0;
            start_pulse      <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_hold   <= s_axi_awaddr;
                aw_hold_valid <= 1'b1;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                wdata_hold   <= s_axi_wdata;
                wstrb_hold   <= s_axi_wstrb;
                w_hold_valid <= 1'b1;
            end

            if (aw_hold_valid && w_hold_valid && !s_axi_bvalid) begin
                write_addr  = awaddr_hold[11:0];
                write_value = apply_wstrb(read_mux(awaddr_hold), wdata_hold, wstrb_hold);

                case (write_addr)
                    ADDR_CTRL: begin
                        ctrl_reg[0] <= write_value[0];
                        ctrl_reg[3] <= write_value[3];
                        soft_reset_pulse <= write_value[1];
                        start_pulse      <= write_value[2];
                    end
                    ADDR_PHASE_INC: begin
                        phase_inc <= write_value;
                    end
                    ADDR_SYMBOL_HOLD: begin
                        symbol_hold_cycles <= write_value;
                    end
                    ADDR_SYMBOL_COUNT: begin
                        symbol_count <= write_value;
                    end
                    default: begin
                    end
                endcase

                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
                s_axi_bvalid  <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_rdata  <= '0;
            s_axi_rvalid <= 1'b0;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rdata  <= read_mux(s_axi_araddr);
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    logic unused_axi_prot;
    assign unused_axi_prot = ^{s_axi_awprot, s_axi_arprot};

endmodule
