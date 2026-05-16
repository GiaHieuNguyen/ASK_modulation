`timescale 1ns / 1ps

module tb_top;

    localparam int PHASE_W    = 32;
    localparam int LUT_ADDR_W = 10;
    localparam int AMP_W      = 16;
    localparam int MULT_W     = 8;

    localparam logic [PHASE_W-1:0] PHASE_INC = 32'd42949673; // 1 MHz @ 100 MHz clk
    localparam string SINE_MEM_FILE = "../tb/carrier_sine.mem";
    localparam string BASEBAND_MEM_FILE = "../tb/baseband_symbols.mem";
    localparam string SIM_SAMPLES_FILE = "../out/sim_samples.csv";
    localparam string BASEBAND_FILE = "../out/baseband_symbols.csv";
    localparam string CONFIG_FILE = "../out/tb_config.csv";

    localparam time CLK_PERIOD = 10ns;
    localparam int DEFAULT_NUM_SYMBOLS = 1024;
    localparam int DEFAULT_HOLD_CYCLES = 1000;
    localparam int MAX_BASEBAND_SYMBOLS = 65536;
    localparam int RESET_CYCLES = 5;
    localparam int FLUSH_CYCLES = 8;
    localparam int MAX_ERRORS = 20;
    localparam int TIMEOUT_MARGIN_CYCLES = 1000;

    logic clk;
    logic rst_n;
    logic [1:0] symbol_in;
    logic signed [AMP_W-1:0] carrier_dbg;
    logic signed [AMP_W-1:0] ask_out;

    logic signed [AMP_W-1:0] ref_sine_rom [0:(1 << LUT_ADDR_W)-1];
    logic [PHASE_W-1:0] ref_phase_acc;
    logic signed [AMP_W-1:0] ref_carrier;
    logic [MULT_W-1:0] ref_scale;
    logic signed [AMP_W+MULT_W:0] ref_full_mult;
    logic signed [AMP_W-1:0] ref_ask;
    logic [LUT_ADDR_W-1:0] ref_lut_addr;
    logic [1:0] baseband_symbols [0:MAX_BASEBAND_SYMBOLS-1];

    int num_symbols;
    int hold_cycles;
    int error_count;
    int valid_cycles;
    int checked_cycles;
    int timeout_cycles;
    int init_idx;
    int symbol_count [0:3];
    int samples_fd;
    int baseband_fd;
    int config_fd;
    bit carrier_bad;
    bit ask_bad;
    event timeout_configured;

    localparam longint unsigned SCALE_MAX = (64'd1 << MULT_W) - 1;
    localparam logic [MULT_W-1:0] SCALE_0 = '0;
    localparam logic [MULT_W-1:0] SCALE_1 = SCALE_MAX / 3;
    localparam logic [MULT_W-1:0] SCALE_2 = (SCALE_MAX * 2) / 3;
    localparam logic [MULT_W-1:0] SCALE_3 = SCALE_MAX;

    top_ask #(
        .PHASE_W(PHASE_W),
        .LUT_ADDR_W(LUT_ADDR_W),
        .AMP_W(AMP_W),
        .MULT_W(MULT_W),
        .PHASE_INC(PHASE_INC),
        .SINE_MEM_FILE(SINE_MEM_FILE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .symbol_in(symbol_in),
        .carrier_dbg(carrier_dbg),
        .ask_out(ask_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    initial begin
        for (init_idx = 0; init_idx < MAX_BASEBAND_SYMBOLS; init_idx++) begin
            baseband_symbols[init_idx] = 2'b00;
        end
        $readmemh(SINE_MEM_FILE, ref_sine_rom);
    end

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

    function automatic logic signed [AMP_W+MULT_W:0] multiply_model(
        input logic signed [AMP_W-1:0] carrier,
        input logic [MULT_W-1:0] scale
    );
        logic signed [MULT_W:0] signed_scale;
        begin
            signed_scale = {1'b0, scale};
            multiply_model = carrier * signed_scale;
        end
    endfunction

    function automatic bit has_unknown(input logic signed [AMP_W-1:0] value);
        begin
            has_unknown = (^value === 1'bx);
        end
    endfunction

    task automatic open_output_files;
        begin
            samples_fd = $fopen(SIM_SAMPLES_FILE, "w");
            if (samples_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", SIM_SAMPLES_FILE);
            end

            baseband_fd = $fopen(BASEBAND_FILE, "w");
            if (baseband_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", BASEBAND_FILE);
            end

            config_fd = $fopen(CONFIG_FILE, "w");
            if (config_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", CONFIG_FILE);
            end

            $fwrite(samples_fd,
                    "cycle,time_ns,symbol_dec,symbol_bin,scale,phase_addr,carrier_dut,ask_dut,carrier_ref,ask_ref,carrier_bad,ask_bad\n");
            $fwrite(baseband_fd,
                    "symbol_index,start_cycle,end_cycle,start_time_ns,symbol_dec,symbol_bin,scale\n");
            $fwrite(config_fd, "key,value\n");
        end
    endtask

    task automatic write_config_file;
        begin
            $fwrite(config_fd, "phase_w,%0d\n", PHASE_W);
            $fwrite(config_fd, "lut_addr_w,%0d\n", LUT_ADDR_W);
            $fwrite(config_fd, "amp_w,%0d\n", AMP_W);
            $fwrite(config_fd, "mult_w,%0d\n", MULT_W);
            $fwrite(config_fd, "phase_inc,%0d\n", PHASE_INC);
            $fwrite(config_fd, "clk_period_ns,%0d\n", CLK_PERIOD / 1ns);
            $fwrite(config_fd, "num_symbols,%0d\n", num_symbols);
            $fwrite(config_fd, "hold_cycles,%0d\n", hold_cycles);
            $fwrite(config_fd, "reset_cycles,%0d\n", RESET_CYCLES);
            $fwrite(config_fd, "flush_cycles,%0d\n", FLUSH_CYCLES);
            $fwrite(config_fd, "timeout_cycles,%0d\n", timeout_cycles);
            $fwrite(config_fd, "sine_mem_file,%s\n", SINE_MEM_FILE);
            $fwrite(config_fd, "baseband_mem_file,%s\n", BASEBAND_MEM_FILE);
            $fwrite(config_fd, "sim_samples_file,%s\n", SIM_SAMPLES_FILE);
            $fwrite(config_fd, "baseband_file,%s\n", BASEBAND_FILE);
            $fflush(config_fd);
        end
    endtask

    task automatic close_output_files;
        begin
            if (samples_fd != 0) begin
                $fflush(samples_fd);
                $fclose(samples_fd);
            end
            if (baseband_fd != 0) begin
                $fflush(baseband_fd);
                $fclose(baseband_fd);
            end
            if (config_fd != 0) begin
                $fflush(config_fd);
                $fclose(config_fd);
            end
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_phase_acc <= '0;
            ref_carrier   <= '0;
            ref_scale     <= '0;
            ref_full_mult <= '0;
            ref_ask       <= '0;
            ref_lut_addr  <= '0;
            valid_cycles  <= 0;
        end else begin
            ref_phase_acc <= ref_phase_acc + PHASE_INC;
            ref_lut_addr  <= ref_phase_acc[PHASE_W-1 -: LUT_ADDR_W];
            ref_carrier   <= ref_sine_rom[ref_phase_acc[PHASE_W-1 -: LUT_ADDR_W]];
            ref_scale     <= symbol_to_scale(symbol_in);
            ref_full_mult <= multiply_model(ref_carrier, ref_scale);
            ref_ask       <= ref_full_mult >>> MULT_W;
            valid_cycles  <= valid_cycles + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            #1;
            carrier_bad = 1'b0;
            ask_bad = 1'b0;

            if (has_unknown(carrier_dbg)) begin
                carrier_bad = 1'b1;
            end else if (carrier_dbg !== ref_carrier) begin
                carrier_bad = 1'b1;
            end

            if (has_unknown(ask_out)) begin
                ask_bad = 1'b1;
            end else if (ask_out !== ref_ask) begin
                ask_bad = 1'b1;
            end

            $fwrite(samples_fd, "%0d,%0t,%0d,%02b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    valid_cycles, $time, symbol_in, symbol_in, ref_scale, ref_lut_addr,
                    carrier_dbg, ask_out, ref_carrier, ref_ask, carrier_bad, ask_bad);

            if (valid_cycles > FLUSH_CYCLES) begin
                checked_cycles++;

                if (carrier_bad && has_unknown(carrier_dbg)) begin
                    error_count++;
                    $display("ERROR cycle=%0d carrier_dbg is unknown", valid_cycles);
                end else if (carrier_bad) begin
                    error_count++;
                    $display("ERROR cycle=%0d carrier mismatch exp=%0d got=%0d",
                             valid_cycles, ref_carrier, carrier_dbg);
                end

                if (ask_bad && has_unknown(ask_out)) begin
                    error_count++;
                    $display("ERROR cycle=%0d ask_out is unknown", valid_cycles);
                end else if (ask_bad) begin
                    error_count++;
                    $display("ERROR cycle=%0d ask mismatch symbol=%b scale=%0d carrier=%0d exp=%0d got=%0d",
                             valid_cycles, symbol_in, ref_scale, ref_carrier, ref_ask, ask_out);
                end

                if (error_count >= MAX_ERRORS) begin
                    $fatal(1, "Stopping after %0d errors", error_count);
                end
            end
        end
    end

    task automatic drive_mem_baseband(input int symbol_total, input int cycles_per_symbol);
        int symbol_idx;
        int start_cycle;
        int end_cycle;
        logic [1:0] next_symbol;
        begin
            @(negedge clk);
            for (symbol_idx = 0; symbol_idx < symbol_total; symbol_idx++) begin
                next_symbol = baseband_symbols[symbol_idx];
                start_cycle = valid_cycles + 1;
                end_cycle = start_cycle + cycles_per_symbol - 1;
                symbol_count[next_symbol]++;
                symbol_in = next_symbol;

                $fwrite(baseband_fd, "%0d,%0d,%0d,%0t,%0d,%02b,%0d\n",
                        symbol_idx, start_cycle, end_cycle, $time,
                        next_symbol, next_symbol, symbol_to_scale(next_symbol));

                repeat (cycles_per_symbol) @(negedge clk);
            end
        end
    endtask

    initial begin
        num_symbols = DEFAULT_NUM_SYMBOLS;
        hold_cycles = DEFAULT_HOLD_CYCLES;
        error_count = 0;
        checked_cycles = 0;
        timeout_cycles = 0;
        symbol_in = 2'b00;
        rst_n = 1'b0;
        open_output_files();

        if ($value$plusargs("symbols=%d", num_symbols)) begin
            $display("Using symbols=%0d", num_symbols);
        end
        if ($value$plusargs("hold=%d", hold_cycles)) begin
            $display("Using hold=%0d cycles/symbol", hold_cycles);
        end

        if (num_symbols <= 0) begin
            $fatal(1, "symbols must be greater than zero");
        end
        if (num_symbols > MAX_BASEBAND_SYMBOLS) begin
            $fatal(1, "symbols=%0d exceeds MAX_BASEBAND_SYMBOLS=%0d", num_symbols, MAX_BASEBAND_SYMBOLS);
        end
        if (hold_cycles <= 0) begin
            $fatal(1, "hold must be greater than zero");
        end

        timeout_cycles = RESET_CYCLES + (num_symbols * hold_cycles) + FLUSH_CYCLES + TIMEOUT_MARGIN_CYCLES;
        -> timeout_configured;

        $readmemh(BASEBAND_MEM_FILE, baseband_symbols, 0, num_symbols - 1);
        write_config_file();

        repeat (RESET_CYCLES) @(negedge clk);
        rst_n = 1'b1;

        $display("Starting ASK simulation: PHASE_INC=%0d symbols=%0d hold=%0d baseband_mem=%s",
                 PHASE_INC, num_symbols, hold_cycles, BASEBAND_MEM_FILE);

        drive_mem_baseband(num_symbols, hold_cycles);
        repeat (FLUSH_CYCLES) @(negedge clk);

        $display("Symbol counts: 00=%0d 01=%0d 10=%0d 11=%0d",
                 symbol_count[0], symbol_count[1], symbol_count[2], symbol_count[3]);
        $display("Checked cycles=%0d errors=%0d", checked_cycles, error_count);

        if (error_count == 0) begin
            $display("PASS: top_ask memory baseband self-check passed");
        end else begin
            $display("FAIL: top_ask memory baseband self-check failed");
        end

        close_output_files();
        $finish;
    end

    initial begin
        @timeout_configured;
        repeat (timeout_cycles) @(posedge clk);
        close_output_files();
        $fatal(1, "Simulation timeout after %0d cycles", timeout_cycles);
    end

endmodule
