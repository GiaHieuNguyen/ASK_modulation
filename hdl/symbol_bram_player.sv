`timescale 1ns / 1ps

module symbol_bram_player #(
    parameter int IFM_ADDR_W = 12
)(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  enable,
    input  logic                  start,
    input  logic                  loop_enable,
    input  logic [31:0]           symbol_count,
    input  logic [31:0]           symbol_hold_cycles,
    input  logic [31:0]           ifm_bram_rdata,
    output logic                  ifm_bram_en,
    output logic [IFM_ADDR_W-1:0] ifm_bram_addr,
    output logic [1:0]            symbol_out,
    output logic                  symbol_valid,
    output logic                  busy,
    output logic                  done,
    output logic [31:0]           current_symbol_index
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_WAIT_FIRST,
        ST_LOAD_FIRST,
        ST_RUN
    } state_t;

    state_t state;
    logic [31:0] hold_counter;
    logic [31:0] hold_limit;
    logic [31:0] next_symbol_index;
    logic [31:0] symbol_count_active;
    logic [31:0] hold_limit_active;
    logic        loop_enable_active;
    logic        has_next_symbol;
    logic [31:0] read_symbol_index;

    function automatic logic [31:0] min_sync_hold(input logic [31:0] value);
        begin
            min_sync_hold = (value < 32'd3) ? 32'd3 : value;
        end
    endfunction

    function automatic logic [IFM_ADDR_W-1:0] word_addr(input logic [31:0] index);
        begin
            word_addr = index[IFM_ADDR_W-1:0];
        end
    endfunction

    always_comb begin
        hold_limit = min_sync_hold(symbol_hold_cycles);
        next_symbol_index = current_symbol_index + 32'd1;
        has_next_symbol = (next_symbol_index < symbol_count_active) || loop_enable_active;
        read_symbol_index = (next_symbol_index < symbol_count_active) ? next_symbol_index : 32'd0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            ifm_bram_en          <= 1'b0;
            ifm_bram_addr        <= '0;
            symbol_out           <= 2'b00;
            symbol_valid         <= 1'b0;
            busy                 <= 1'b0;
            done                 <= 1'b0;
            current_symbol_index <= 32'd0;
            hold_counter         <= 32'd0;
            symbol_count_active  <= 32'd0;
            hold_limit_active    <= 32'd3;
            loop_enable_active   <= 1'b0;
        end else begin
            ifm_bram_en <= 1'b0;

            case (state)
                ST_IDLE: begin
                    symbol_valid <= 1'b0;
                    busy         <= 1'b0;

                    if (enable && start && (symbol_count != 32'd0)) begin
                        done                 <= 1'b0;
                        busy                 <= 1'b1;
                        current_symbol_index <= 32'd0;
                        hold_counter         <= 32'd0;
                        symbol_count_active  <= symbol_count;
                        hold_limit_active    <= hold_limit;
                        loop_enable_active   <= loop_enable;
                        ifm_bram_addr        <= '0;
                        ifm_bram_en          <= 1'b1;
                        state                <= ST_WAIT_FIRST;
                    end
                end

                ST_WAIT_FIRST: begin
                    busy         <= 1'b1;
                    symbol_valid <= 1'b0;
                    state        <= ST_LOAD_FIRST;
                end

                ST_LOAD_FIRST: begin
                    if (!enable) begin
                        state        <= ST_IDLE;
                        busy         <= 1'b0;
                        symbol_valid <= 1'b0;
                    end else begin
                        symbol_out           <= ifm_bram_rdata[1:0];
                        symbol_valid         <= 1'b1;
                        busy                 <= 1'b1;
                        current_symbol_index <= 32'd0;
                        hold_counter         <= 32'd1;
                        state                <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (!enable) begin
                        state        <= ST_IDLE;
                        busy         <= 1'b0;
                        symbol_valid <= 1'b0;
                    end else if ((hold_counter == (hold_limit_active - 32'd2)) && has_next_symbol) begin
                        ifm_bram_addr <= word_addr(read_symbol_index);
                        ifm_bram_en   <= 1'b1;
                        hold_counter  <= hold_counter + 32'd1;
                    end else if (hold_counter >= hold_limit_active) begin
                        hold_counter <= 32'd0;

                        if (next_symbol_index < symbol_count_active) begin
                            current_symbol_index <= next_symbol_index;
                            symbol_out           <= ifm_bram_rdata[1:0];
                            hold_counter         <= 32'd1;
                        end else if (loop_enable_active) begin
                            current_symbol_index <= 32'd0;
                            symbol_out           <= ifm_bram_rdata[1:0];
                            hold_counter         <= 32'd1;
                        end else begin
                            state        <= ST_IDLE;
                            busy         <= 1'b0;
                            done         <= 1'b1;
                            symbol_valid <= 1'b0;
                        end
                    end else begin
                        hold_counter <= hold_counter + 32'd1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
