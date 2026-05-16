`timescale 1ns / 1ps

module tb_ask_modulator_axi;

    localparam int PHASE_W    = 32;
    localparam int LUT_ADDR_W = 10;
    localparam int AMP_W      = 16;
    localparam int MULT_W     = 8;
    localparam int AXI_ADDR_W = 12;
    localparam int IFM_ADDR_W = 12;
    localparam int IFM_DEPTH  = (1 << IFM_ADDR_W);

    localparam logic [PHASE_W-1:0] DEFAULT_PHASE_INC = 32'd42949673; // 1 MHz @ 100 MHz clk
    localparam string SINE_MEM_FILE = "../tb/carrier_sine.mem";
    localparam string BASEBAND_MEM_FILE = "../tb/baseband_symbols.mem";
    localparam string AXI_SAMPLES_FILE = "../out/axi_ifm_samples.csv";
    localparam string AXI_BASEBAND_FILE = "../out/axi_ifm_baseband_symbols.csv";
    localparam string AXI_CONFIG_FILE = "../out/axi_ifm_config.csv";

    localparam logic [AXI_ADDR_W-1:0] ADDR_CTRL                 = 12'h000;
    localparam logic [AXI_ADDR_W-1:0] ADDR_STATUS               = 12'h004;
    localparam logic [AXI_ADDR_W-1:0] ADDR_PHASE_INC            = 12'h008;
    localparam logic [AXI_ADDR_W-1:0] ADDR_SYMBOL_HOLD          = 12'h00C;
    localparam logic [AXI_ADDR_W-1:0] ADDR_SYMBOL_COUNT         = 12'h010;
    localparam logic [AXI_ADDR_W-1:0] ADDR_CURRENT_SYMBOL       = 12'h014;
    localparam logic [AXI_ADDR_W-1:0] ADDR_CURRENT_SYMBOL_INDEX = 12'h018;
    localparam logic [AXI_ADDR_W-1:0] ADDR_CURRENT_CARRIER      = 12'h01C;
    localparam logic [AXI_ADDR_W-1:0] ADDR_CURRENT_ASK          = 12'h020;

    localparam logic [31:0] CTRL_ENABLE = 32'h0000_0001;
    localparam logic [31:0] CTRL_START  = 32'h0000_0004;
    localparam logic [31:0] STATUS_DONE = 32'h0000_0004;

    localparam time CLK_PERIOD = 10ns;
    localparam int DEFAULT_NUM_SYMBOLS = 1024;
    localparam int DEFAULT_HOLD_CYCLES = 1000;
    localparam int RESET_CYCLES = 5;
    localparam int FLUSH_CYCLES = 8;
    localparam int MAX_ERRORS = 20;
    localparam int TIMEOUT_MARGIN_CYCLES = 5000;

    logic clk;
    logic rst_n;

    logic [AXI_ADDR_W-1:0] axi_awaddr;
    logic [2:0] axi_awprot;
    logic axi_awvalid;
    logic axi_awready;
    logic [31:0] axi_wdata;
    logic [3:0] axi_wstrb;
    logic axi_wvalid;
    logic axi_wready;
    logic [1:0] axi_bresp;
    logic axi_bvalid;
    logic axi_bready;
    logic [AXI_ADDR_W-1:0] axi_araddr;
    logic [2:0] axi_arprot;
    logic axi_arvalid;
    logic axi_arready;
    logic [31:0] axi_rdata;
    logic [1:0] axi_rresp;
    logic axi_rvalid;
    logic axi_rready;

    logic [31:0] ifm_mem [0:IFM_DEPTH-1];
    logic [31:0] ifm_bram_rdata;
    logic ifm_bram_en;
    logic [IFM_ADDR_W-1:0] ifm_bram_addr;

    logic signed [AMP_W-1:0] ask_out;
    logic signed [AMP_W-1:0] carrier_dbg;
    logic [AMP_W-1:0] dac_data;
    logic [1:0] symbol_dbg;
    logic symbol_valid_dbg;
    wire datapath_rst_n_mon;

    logic signed [AMP_W-1:0] ref_sine_rom [0:(1 << LUT_ADDR_W)-1];
    logic [PHASE_W-1:0] ref_phase_acc;
    logic signed [AMP_W-1:0] ref_carrier;
    logic [MULT_W-1:0] ref_scale;
    logic signed [AMP_W+MULT_W:0] ref_full_mult;
    logic signed [AMP_W-1:0] ref_ask;
    logic [LUT_ADDR_W-1:0] ref_lut_addr;

    int num_symbols;
    int hold_cycles;
    int effective_hold_cycles;
    int timeout_cycles;
    int error_count;
    int checked_cycles;
    int valid_cycles;
    int symbol_output_cycles;
    int expected_symbol_index;
    int expected_hold_counter;
    int init_idx;
    int symbol_idx;
    int symbol_count [0:3];
    int samples_fd;
    int baseband_fd;
    int config_fd;
    logic [31:0] phase_inc_cfg;
    logic [31:0] status_word;
    logic [31:0] readback_word;
    logic [1:0] expected_symbol;
    bit symbol_model_active;
    bit carrier_bad;
    bit ask_bad;
    bit symbol_bad;
    event timeout_configured;

    localparam longint unsigned SCALE_MAX = (64'd1 << MULT_W) - 1;
    localparam logic [MULT_W-1:0] SCALE_0 = '0;
    localparam logic [MULT_W-1:0] SCALE_1 = SCALE_MAX / 3;
    localparam logic [MULT_W-1:0] SCALE_2 = (SCALE_MAX * 2) / 3;
    localparam logic [MULT_W-1:0] SCALE_3 = SCALE_MAX;

    ask_modulator #(
        .PHASE_W(PHASE_W),
        .LUT_ADDR_W(LUT_ADDR_W),
        .AMP_W(AMP_W),
        .MULT_W(MULT_W),
        .AXI_ADDR_W(AXI_ADDR_W),
        .IFM_ADDR_W(IFM_ADDR_W),
        .SINE_MEM_FILE(SINE_MEM_FILE),
        .DEFAULT_PHASE_INC(DEFAULT_PHASE_INC),
        .DEFAULT_SYMBOL_HOLD_CYCLES(DEFAULT_HOLD_CYCLES),
        .DEFAULT_SYMBOL_COUNT(DEFAULT_NUM_SYMBOLS)
    ) dut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(rst_n),
        .s_axi_awaddr(axi_awaddr),
        .s_axi_awprot(axi_awprot),
        .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata),
        .s_axi_wstrb(axi_wstrb),
        .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready),
        .s_axi_bresp(axi_bresp),
        .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_araddr(axi_araddr),
        .s_axi_arprot(axi_arprot),
        .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready),
        .s_axi_rdata(axi_rdata),
        .s_axi_rresp(axi_rresp),
        .s_axi_rvalid(axi_rvalid),
        .s_axi_rready(axi_rready),
        .ifm_bram_rdata(ifm_bram_rdata),
        .ifm_bram_en(ifm_bram_en),
        .ifm_bram_addr(ifm_bram_addr),
        .ask_out(ask_out),
        .carrier_dbg(carrier_dbg),
        .dac_data(dac_data),
        .symbol_dbg(symbol_dbg),
        .symbol_valid_dbg(symbol_valid_dbg)
    );

    axi_master_bfm #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_DATA_W(32)
    ) u_axi (
        .clk(clk),
        .rst_n(rst_n),
        .m_axi_awaddr(axi_awaddr),
        .m_axi_awprot(axi_awprot),
        .m_axi_awvalid(axi_awvalid),
        .m_axi_awready(axi_awready),
        .m_axi_wdata(axi_wdata),
        .m_axi_wstrb(axi_wstrb),
        .m_axi_wvalid(axi_wvalid),
        .m_axi_wready(axi_wready),
        .m_axi_bresp(axi_bresp),
        .m_axi_bvalid(axi_bvalid),
        .m_axi_bready(axi_bready),
        .m_axi_araddr(axi_araddr),
        .m_axi_arprot(axi_arprot),
        .m_axi_arvalid(axi_arvalid),
        .m_axi_arready(axi_arready),
        .m_axi_rdata(axi_rdata),
        .m_axi_rresp(axi_rresp),
        .m_axi_rvalid(axi_rvalid),
        .m_axi_rready(axi_rready)
    );

    assign datapath_rst_n_mon = dut.datapath_rst_n;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    always @(posedge clk) begin
        if (ifm_bram_en) begin
            ifm_bram_rdata <= ifm_mem[ifm_bram_addr];
        end
    end

    function automatic int effective_hold(input int requested_hold);
        begin
            effective_hold = (requested_hold < 3) ? 3 : requested_hold;
        end
    endfunction

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

    function automatic bit has_unknown_amp(input logic signed [AMP_W-1:0] value);
        begin
            has_unknown_amp = (^value === 1'bx);
        end
    endfunction

    function automatic bit has_unknown_symbol(input logic [1:0] value);
        begin
            has_unknown_symbol = (^value === 1'bx);
        end
    endfunction

    task automatic open_output_files;
        begin
            samples_fd = $fopen(AXI_SAMPLES_FILE, "w");
            if (samples_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", AXI_SAMPLES_FILE);
            end

            baseband_fd = $fopen(AXI_BASEBAND_FILE, "w");
            if (baseband_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", AXI_BASEBAND_FILE);
            end

            config_fd = $fopen(AXI_CONFIG_FILE, "w");
            if (config_fd == 0) begin
                $fatal(1, "Could not open %s. Create sim/out before running simulation.", AXI_CONFIG_FILE);
            end

            $fwrite(samples_fd,
                    "cycle,time_ns,symbol_valid,symbol_index,hold_counter,symbol_dec,symbol_bin,scale,phase_addr,carrier_dut,ask_dut,carrier_ref,ask_ref,carrier_bad,ask_bad,symbol_bad\n");
            $fwrite(baseband_fd, "symbol_index,symbol_dec,symbol_bin,scale,ifm_word_hex\n");
            $fwrite(config_fd, "key,value\n");
        end
    endtask

    task automatic close_output_files;
        begin
            if (samples_fd != 0) begin
                $fflush(samples_fd);
                $fclose(samples_fd);
                samples_fd = 0;
            end
            if (baseband_fd != 0) begin
                $fflush(baseband_fd);
                $fclose(baseband_fd);
                baseband_fd = 0;
            end
            if (config_fd != 0) begin
                $fflush(config_fd);
                $fclose(config_fd);
                config_fd = 0;
            end
        end
    endtask

    task automatic write_config_file;
        begin
            $fwrite(config_fd, "phase_w,%0d\n", PHASE_W);
            $fwrite(config_fd, "lut_addr_w,%0d\n", LUT_ADDR_W);
            $fwrite(config_fd, "amp_w,%0d\n", AMP_W);
            $fwrite(config_fd, "mult_w,%0d\n", MULT_W);
            $fwrite(config_fd, "axi_addr_w,%0d\n", AXI_ADDR_W);
            $fwrite(config_fd, "ifm_addr_w,%0d\n", IFM_ADDR_W);
            $fwrite(config_fd, "ifm_depth_words,%0d\n", IFM_DEPTH);
            $fwrite(config_fd, "phase_inc,%0d\n", phase_inc_cfg);
            $fwrite(config_fd, "clk_period_ns,%0d\n", CLK_PERIOD / 1ns);
            $fwrite(config_fd, "num_symbols,%0d\n", num_symbols);
            $fwrite(config_fd, "requested_hold_cycles,%0d\n", hold_cycles);
            $fwrite(config_fd, "effective_hold_cycles,%0d\n", effective_hold_cycles);
            $fwrite(config_fd, "reset_cycles,%0d\n", RESET_CYCLES);
            $fwrite(config_fd, "flush_cycles,%0d\n", FLUSH_CYCLES);
            $fwrite(config_fd, "timeout_cycles,%0d\n", timeout_cycles);
            $fwrite(config_fd, "sine_mem_file,%s\n", SINE_MEM_FILE);
            $fwrite(config_fd, "baseband_mem_file,%s\n", BASEBAND_MEM_FILE);
            $fwrite(config_fd, "axi_samples_file,%s\n", AXI_SAMPLES_FILE);
            $fwrite(config_fd, "axi_baseband_file,%s\n", AXI_BASEBAND_FILE);
            $fflush(config_fd);
        end
    endtask

    task automatic write_baseband_review_file;
        begin
            for (symbol_idx = 0; symbol_idx < num_symbols; symbol_idx++) begin
                symbol_count[ifm_mem[symbol_idx][1:0]]++;
                $fwrite(baseband_fd, "%0d,%0d,%02b,%0d,%08h\n",
                        symbol_idx,
                        ifm_mem[symbol_idx][1:0],
                        ifm_mem[symbol_idx][1:0],
                        symbol_to_scale(ifm_mem[symbol_idx][1:0]),
                        ifm_mem[symbol_idx]);
            end
            $fflush(baseband_fd);
        end
    endtask

    always_ff @(posedge clk or negedge datapath_rst_n_mon) begin
        if (!datapath_rst_n_mon) begin
            ref_phase_acc <= '0;
            ref_carrier   <= '0;
            ref_scale     <= '0;
            ref_full_mult <= '0;
            ref_ask       <= '0;
            ref_lut_addr  <= '0;
            valid_cycles  <= 0;
        end else begin
            ref_phase_acc <= ref_phase_acc + phase_inc_cfg[PHASE_W-1:0];
            ref_lut_addr  <= ref_phase_acc[PHASE_W-1 -: LUT_ADDR_W];
            ref_carrier   <= ref_sine_rom[ref_phase_acc[PHASE_W-1 -: LUT_ADDR_W]];
            ref_scale     <= symbol_to_scale(symbol_dbg);
            ref_full_mult <= multiply_model(ref_carrier, ref_scale);
            ref_ask       <= ref_full_mult >>> MULT_W;
            valid_cycles  <= valid_cycles + 1;
        end
    end

    always @(posedge clk) begin
        if (datapath_rst_n_mon) begin
            #1;
            carrier_bad = 1'b0;
            ask_bad = 1'b0;
            symbol_bad = 1'b0;

            if (symbol_valid_dbg) begin
                if (!symbol_model_active) begin
                    symbol_model_active = 1'b1;
                    expected_symbol_index = 0;
                    expected_hold_counter = 1;
                end

                expected_symbol = ifm_mem[expected_symbol_index][1:0];
                if (has_unknown_symbol(symbol_dbg) || (symbol_dbg !== expected_symbol)) begin
                    symbol_bad = 1'b1;
                end

                if (has_unknown_amp(carrier_dbg) || (carrier_dbg !== ref_carrier)) begin
                    carrier_bad = 1'b1;
                end

                if (has_unknown_amp(ask_out) || (ask_out !== ref_ask)) begin
                    ask_bad = 1'b1;
                end

                symbol_output_cycles++;

                if (expected_hold_counter >= effective_hold_cycles) begin
                    expected_symbol_index++;
                    expected_hold_counter = 1;
                    if (expected_symbol_index >= num_symbols) begin
                        symbol_model_active = 1'b0;
                    end
                end else begin
                    expected_hold_counter++;
                end
            end else if (ask_out !== '0) begin
                ask_bad = 1'b1;
            end

            if (samples_fd != 0) begin
                $fwrite(samples_fd, "%0d,%0t,%0d,%0d,%0d,%0d,%02b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        valid_cycles, $time, symbol_valid_dbg, expected_symbol_index,
                        expected_hold_counter, symbol_dbg, symbol_dbg, ref_scale,
                        ref_lut_addr, carrier_dbg, ask_out, ref_carrier, ref_ask,
                        carrier_bad, ask_bad, symbol_bad);
            end

            if (valid_cycles > FLUSH_CYCLES) begin
                if (symbol_bad) begin
                    error_count++;
                    $display("ERROR cycle=%0d symbol mismatch index=%0d exp=%b got=%b",
                             valid_cycles, expected_symbol_index, expected_symbol, symbol_dbg);
                end

                if (symbol_valid_dbg) begin
                    checked_cycles++;

                    if (carrier_bad) begin
                        error_count++;
                        $display("ERROR cycle=%0d carrier mismatch exp=%0d got=%0d",
                                 valid_cycles, ref_carrier, carrier_dbg);
                    end

                    if (ask_bad) begin
                        error_count++;
                        $display("ERROR cycle=%0d ask mismatch symbol=%b scale=%0d carrier=%0d exp=%0d got=%0d",
                                 valid_cycles, symbol_dbg, ref_scale, ref_carrier, ref_ask, ask_out);
                    end
                end else if (ask_bad) begin
                    error_count++;
                    $display("ERROR cycle=%0d ask_out should be zero while symbol_valid=0, got=%0d",
                             valid_cycles, ask_out);
                end

                if (error_count >= MAX_ERRORS) begin
                    close_output_files();
                    $fatal(1, "Stopping after %0d errors", error_count);
                end
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        ifm_bram_rdata = 32'd0;
        num_symbols = DEFAULT_NUM_SYMBOLS;
        hold_cycles = DEFAULT_HOLD_CYCLES;
        phase_inc_cfg = DEFAULT_PHASE_INC;
        effective_hold_cycles = DEFAULT_HOLD_CYCLES;
        timeout_cycles = 0;
        error_count = 0;
        checked_cycles = 0;
        symbol_output_cycles = 0;
        expected_symbol_index = 0;
        expected_hold_counter = 0;
        symbol_model_active = 1'b0;
        samples_fd = 0;
        baseband_fd = 0;
        config_fd = 0;
        status_word = 32'd0;
        readback_word = 32'd0;
        u_axi.init_master();

        for (init_idx = 0; init_idx < IFM_DEPTH; init_idx++) begin
            ifm_mem[init_idx] = 32'd0;
        end
        for (init_idx = 0; init_idx < 4; init_idx++) begin
            symbol_count[init_idx] = 0;
        end
        $readmemh(SINE_MEM_FILE, ref_sine_rom);

        if ($value$plusargs("symbols=%d", num_symbols)) begin
            $display("Using symbols=%0d", num_symbols);
        end
        if ($value$plusargs("hold=%d", hold_cycles)) begin
            $display("Using hold=%0d cycles/symbol", hold_cycles);
        end
        if ($value$plusargs("phase_inc=%d", phase_inc_cfg)) begin
            $display("Using phase_inc=%0d", phase_inc_cfg);
        end

        if (num_symbols <= 0) begin
            $fatal(1, "symbols must be greater than zero");
        end
        if (num_symbols > IFM_DEPTH) begin
            $fatal(1, "symbols=%0d exceeds IFM_DEPTH=%0d. Increase IFM_ADDR_W.", num_symbols, IFM_DEPTH);
        end
        if (hold_cycles <= 0) begin
            $fatal(1, "hold must be greater than zero");
        end

        effective_hold_cycles = effective_hold(hold_cycles);
        timeout_cycles = RESET_CYCLES + 200 + (num_symbols * effective_hold_cycles) + FLUSH_CYCLES + TIMEOUT_MARGIN_CYCLES;
        -> timeout_configured;

        $readmemh(BASEBAND_MEM_FILE, ifm_mem, 0, num_symbols - 1);
        open_output_files();
        write_baseband_review_file();
        write_config_file();

        repeat (RESET_CYCLES) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        $display("Starting AXI ASK simulation: PHASE_INC=%0d symbols=%0d hold=%0d effective_hold=%0d baseband_mem=%s",
                 phase_inc_cfg, num_symbols, hold_cycles, effective_hold_cycles, BASEBAND_MEM_FILE);

        u_axi.write_reg(ADDR_PHASE_INC, phase_inc_cfg);
        u_axi.write_reg(ADDR_SYMBOL_HOLD, hold_cycles);
        u_axi.write_reg(ADDR_SYMBOL_COUNT, num_symbols);
        u_axi.write_reg(ADDR_CTRL, CTRL_ENABLE | CTRL_START);

        u_axi.read_reg(ADDR_PHASE_INC, readback_word);
        if (readback_word !== phase_inc_cfg) begin
            error_count++;
            $display("ERROR PHASE_INC readback mismatch exp=%0d got=%0d", phase_inc_cfg, readback_word);
        end

        do begin
            repeat (100) @(posedge clk);
            u_axi.read_reg(ADDR_STATUS, status_word);
        end while ((status_word & STATUS_DONE) == 32'd0);

        u_axi.read_reg(ADDR_CURRENT_SYMBOL, readback_word);
        u_axi.read_reg(ADDR_CURRENT_SYMBOL_INDEX, readback_word);
        u_axi.read_reg(ADDR_CURRENT_CARRIER, readback_word);
        u_axi.read_reg(ADDR_CURRENT_ASK, readback_word);

        repeat (FLUSH_CYCLES) @(posedge clk);

        if (symbol_output_cycles != (num_symbols * effective_hold_cycles)) begin
            error_count++;
            $display("ERROR symbol output cycle count mismatch exp=%0d got=%0d",
                     num_symbols * effective_hold_cycles, symbol_output_cycles);
        end

        $display("Symbol counts: 00=%0d 01=%0d 10=%0d 11=%0d",
                 symbol_count[0], symbol_count[1], symbol_count[2], symbol_count[3]);
        $display("Checked cycles=%0d symbol_output_cycles=%0d errors=%0d",
                 checked_cycles, symbol_output_cycles, error_count);

        if (error_count == 0) begin
            $display("PASS: ask_modulator AXI IFM BRAM self-check passed");
        end else begin
            $display("FAIL: ask_modulator AXI IFM BRAM self-check failed");
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
