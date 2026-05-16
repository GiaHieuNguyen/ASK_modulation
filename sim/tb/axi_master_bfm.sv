`timescale 1ns / 1ps

module axi_master_bfm #(
    parameter int AXI_ADDR_W = 12,
    parameter int AXI_DATA_W = 32
)(
    input  logic                      clk,
    input  logic                      rst_n,

    output logic [AXI_ADDR_W-1:0]     m_axi_awaddr,
    output logic [2:0]                m_axi_awprot,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    output logic [AXI_DATA_W-1:0]     m_axi_wdata,
    output logic [(AXI_DATA_W/8)-1:0] m_axi_wstrb,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,

    input  logic [1:0]                m_axi_bresp,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,

    output logic [AXI_ADDR_W-1:0]     m_axi_araddr,
    output logic [2:0]                m_axi_arprot,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    input  logic [AXI_DATA_W-1:0]     m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready
);

    task automatic init_master;
        begin
            m_axi_awaddr  <= '0;
            m_axi_awprot  <= 3'b000;
            m_axi_awvalid <= 1'b0;
            m_axi_wdata   <= '0;
            m_axi_wstrb   <= '0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            m_axi_araddr  <= '0;
            m_axi_arprot  <= 3'b000;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
        end
    endtask

    task automatic write_reg(
        input logic [AXI_ADDR_W-1:0]     addr,
        input logic [AXI_DATA_W-1:0]     data,
        input logic [(AXI_DATA_W/8)-1:0] strb = '1
    );
        bit aw_done;
        bit w_done;
        begin
            aw_done = 1'b0;
            w_done  = 1'b0;

            m_axi_awaddr  <= addr;
            m_axi_awprot  <= 3'b000;
            m_axi_awvalid <= 1'b1;
            m_axi_wdata   <= data;
            m_axi_wstrb   <= strb;
            m_axi_wvalid  <= 1'b1;
            m_axi_bready  <= 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge clk);
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    aw_done = 1'b1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    w_done = 1'b1;
                end
            end

            do begin
                @(posedge clk);
            end while (!m_axi_bvalid);

            if (m_axi_bresp != 2'b00) begin
                $fatal(1, "AXI write error addr=0x%0h bresp=%0b", addr, m_axi_bresp);
            end

            @(posedge clk);
            m_axi_bready <= 1'b0;
        end
    endtask

    task automatic read_reg(
        input  logic [AXI_ADDR_W-1:0] addr,
        output logic [AXI_DATA_W-1:0] data
    );
        bit ar_done;
        begin
            ar_done = 1'b0;

            m_axi_araddr  <= addr;
            m_axi_arprot  <= 3'b000;
            m_axi_arvalid <= 1'b1;
            m_axi_rready  <= 1'b1;

            while (!ar_done) begin
                @(posedge clk);
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    ar_done = 1'b1;
                end
            end

            do begin
                @(posedge clk);
            end while (!m_axi_rvalid);

            data = m_axi_rdata;
            if (m_axi_rresp != 2'b00) begin
                $fatal(1, "AXI read error addr=0x%0h rresp=%0b", addr, m_axi_rresp);
            end

            @(posedge clk);
            m_axi_rready <= 1'b0;
        end
    endtask

    logic unused_reset;
    assign unused_reset = rst_n;

endmodule
