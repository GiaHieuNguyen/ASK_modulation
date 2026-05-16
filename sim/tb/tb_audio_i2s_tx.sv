`timescale 1ns / 1ps

module tb_audio_i2s_tx;

    localparam time CLK_PERIOD = 10ns;
    localparam int SAMPLE_W = 16;
    localparam int AUDIO_W = 24;
    localparam int SLOT_W = 32;
    localparam int FRAME_BITS = 2 * SLOT_W;
    localparam int MCLK_PERIOD_CYCLES = 10;
    localparam int BCLK_PERIOD_CYCLES = 32;
    localparam int LRCLK_PERIOD_CYCLES = 2048;

    logic clk;
    logic rst_n;
    logic signed [SAMPLE_W-1:0] sample_in;
    logic sample_valid;
    logic codec_mclk;
    logic codec_bclk;
    logic codec_lrclk;
    logic codec_sdata_o;

    int clk_cycles;
    int error_count;

    audio_i2s_tx #(
        .SAMPLE_W(SAMPLE_W),
        .AUDIO_W(AUDIO_W),
        .SLOT_W(SLOT_W),
        .MCLK_HALF_CYCLES(5),
        .BCLK_HALF_CYCLES(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_in(sample_in),
        .sample_valid(sample_valid),
        .codec_mclk(codec_mclk),
        .codec_bclk(codec_bclk),
        .codec_lrclk(codec_lrclk),
        .codec_sdata_o(codec_sdata_o)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            clk_cycles <= 0;
        end else begin
            clk_cycles <= clk_cycles + 1;
        end
    end

    function automatic logic signed [AUDIO_W-1:0] expand_sample(
        input logic signed [SAMPLE_W-1:0] sample
    );
        begin
            expand_sample = $signed({sample, {(AUDIO_W-SAMPLE_W){1'b0}}});
        end
    endfunction

    function automatic logic expected_frame_bit(
        input int bit_pos,
        input logic signed [AUDIO_W-1:0] sample
    );
        int channel_bit;
        begin
            channel_bit = bit_pos % SLOT_W;

            if (channel_bit == 0) begin
                expected_frame_bit = 1'b0;
            end else if (channel_bit <= AUDIO_W) begin
                expected_frame_bit = sample[AUDIO_W-channel_bit];
            end else begin
                expected_frame_bit = 1'b0;
            end
        end
    endfunction

    task automatic check_period(
        input string name,
        input int expected_cycles,
        ref logic signal
    );
        int start_cycle;
        int stop_cycle;
        begin
            @(posedge signal);
            start_cycle = clk_cycles;
            @(posedge signal);
            stop_cycle = clk_cycles;

            if ((stop_cycle - start_cycle) != expected_cycles) begin
                error_count++;
                $display("ERROR %s period cycles expected=%0d got=%0d",
                         name, expected_cycles, stop_cycle - start_cycle);
            end
        end
    endtask

    task automatic capture_frame(output logic [FRAME_BITS-1:0] bits);
        int bit_idx;
        begin
            @(posedge codec_lrclk);
            @(negedge codec_lrclk);
            for (bit_idx = 0; bit_idx < FRAME_BITS; bit_idx++) begin
                @(posedge codec_bclk);
                bits[FRAME_BITS-1-bit_idx] = codec_sdata_o;
            end
        end
    endtask

    task automatic check_frame(
        input string frame_name,
        input logic [FRAME_BITS-1:0] bits,
        input logic signed [AUDIO_W-1:0] expected_sample
    );
        int bit_idx;
        logic expected_bit;
        logic got_bit;
        begin
            for (bit_idx = 0; bit_idx < FRAME_BITS; bit_idx++) begin
                expected_bit = expected_frame_bit(bit_idx, expected_sample);
                got_bit = bits[FRAME_BITS-1-bit_idx];
                if (got_bit !== expected_bit) begin
                    error_count++;
                    $display("ERROR %s bit[%0d] expected=%0b got=%0b",
                             frame_name, bit_idx, expected_bit, got_bit);
                end
            end
        end
    endtask

    initial begin
        logic [FRAME_BITS-1:0] frame_bits;

        rst_n = 1'b0;
        sample_in = '0;
        sample_valid = 1'b0;
        error_count = 0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        fork
            check_period("MCLK", MCLK_PERIOD_CYCLES, codec_mclk);
            check_period("BCLK", BCLK_PERIOD_CYCLES, codec_bclk);
            check_period("LRCLK", LRCLK_PERIOD_CYCLES, codec_lrclk);
        join

        sample_in = 16'sh1234;
        sample_valid = 1'b1;
        capture_frame(frame_bits);
        check_frame("nonzero frame", frame_bits, expand_sample(16'sh1234));

        sample_valid = 1'b0;
        capture_frame(frame_bits);
        check_frame("silence frame", frame_bits, '0);

        if (error_count == 0) begin
            $display("PASS: audio_i2s_tx self-check passed");
        end else begin
            $fatal(1, "FAIL: audio_i2s_tx self-check failed with %0d errors", error_count);
        end

        $finish;
    end

endmodule
