`timescale 1ns / 1ps

module audio_i2s_tx #(
    parameter int SAMPLE_W = 16,
    parameter int AUDIO_W = 24,
    parameter int SLOT_W = 32,
    parameter int MCLK_HALF_CYCLES = 5,
    parameter int BCLK_HALF_CYCLES = 16
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic signed [SAMPLE_W-1:0]   sample_in,
    input  logic                         sample_valid,
    output logic                         codec_mclk,
    output logic                         codec_bclk,
    output logic                         codec_lrclk,
    output logic                         codec_sdata_o
);

    localparam int FRAME_BITS = 2 * SLOT_W;
    localparam int MCLK_DIV_W = (MCLK_HALF_CYCLES <= 1) ? 1 : $clog2(MCLK_HALF_CYCLES);
    localparam int BCLK_DIV_W = (BCLK_HALF_CYCLES <= 1) ? 1 : $clog2(BCLK_HALF_CYCLES);
    localparam int BIT_IDX_W = (FRAME_BITS <= 1) ? 1 : $clog2(FRAME_BITS);
    localparam int SLOT_PAD_W = SLOT_W - AUDIO_W - 1;

    logic [MCLK_DIV_W-1:0] mclk_div_counter;
    logic [BCLK_DIV_W-1:0] bclk_div_counter;
    logic [BIT_IDX_W-1:0]  bit_index;
    logic signed [AUDIO_W-1:0] frame_sample;
    logic [FRAME_BITS-1:0] frame_shift;
    logic [FRAME_BITS-1:0] load_frame;

    function automatic logic signed [AUDIO_W-1:0] expand_sample(
        input logic signed [SAMPLE_W-1:0] sample
    );
        begin
            if (AUDIO_W >= SAMPLE_W) begin
                expand_sample = $signed({sample, {(AUDIO_W-SAMPLE_W){1'b0}}});
            end else begin
                expand_sample = sample[SAMPLE_W-1 -: AUDIO_W];
            end
        end
    endfunction

    function automatic logic [FRAME_BITS-1:0] build_frame(
        input logic signed [AUDIO_W-1:0] sample
    );
        logic [SLOT_W-1:0] slot;
        begin
            slot = {1'b0, sample, {SLOT_PAD_W{1'b0}}};
            build_frame = {slot, slot};
        end
    endfunction

    assign load_frame = build_frame(sample_valid ? expand_sample(sample_in) : '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            codec_mclk       <= 1'b0;
            mclk_div_counter <= '0;
        end else if (mclk_div_counter == (MCLK_HALF_CYCLES - 1)) begin
            mclk_div_counter <= '0;
            codec_mclk       <= ~codec_mclk;
        end else begin
            mclk_div_counter <= mclk_div_counter + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            codec_bclk       <= 1'b0;
            codec_lrclk      <= 1'b0;
            codec_sdata_o    <= 1'b0;
            bclk_div_counter <= '0;
            bit_index        <= '0;
            frame_sample     <= '0;
            frame_shift      <= '0;
        end else if (bclk_div_counter == (BCLK_HALF_CYCLES - 1)) begin
            bclk_div_counter <= '0;
            codec_bclk       <= ~codec_bclk;

            if (codec_bclk) begin
                codec_lrclk   <= (bit_index >= SLOT_W);

                if (bit_index == '0) begin
                    frame_sample  <= sample_valid ? expand_sample(sample_in) : '0;
                    frame_shift   <= {load_frame[FRAME_BITS-2:0], 1'b0};
                    codec_sdata_o <= load_frame[FRAME_BITS-1];
                end else begin
                    frame_shift   <= {frame_shift[FRAME_BITS-2:0], 1'b0};
                    codec_sdata_o <= frame_shift[FRAME_BITS-1];
                end

                if (bit_index == (FRAME_BITS - 1)) begin
                    bit_index <= '0;
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end else begin
            bclk_div_counter <= bclk_div_counter + 1'b1;
        end
    end

endmodule
