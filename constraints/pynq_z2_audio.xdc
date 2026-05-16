## PYNQ-Z2 ADAU1761 audio codec pins for ask_audio_top.
## These pin assignments follow the PYNQ-Z2 base overlay/master XDC naming.

set_property -dict { PACKAGE_PIN U5  IOSTANDARD LVCMOS33 } [get_ports { codec_mclk }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { codec_bclk }]
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports { codec_lrclk }]
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports { codec_sdata_o }]

## Add these constraints in the block design if codec I2C is routed through PL
## as AXI IIC or PS I2C over EMIO. The Python codec init needs this bus.
##
## set_property -dict { PACKAGE_PIN U9 IOSTANDARD LVCMOS33 } [get_ports { IIC_1_scl_io }]
## set_property PULLUP true [get_ports { IIC_1_scl_io }]
## set_property -dict { PACKAGE_PIN T9 IOSTANDARD LVCMOS33 } [get_ports { IIC_1_sda_io }]
## set_property PULLUP true [get_ports { IIC_1_sda_io }]
