# ASK Modulation Project Current Process

Last updated: 2026-05-12

## Final Goal

Build a 4-ASK modulator in SystemVerilog, package it as a Vivado 2024.2 AXI4-Lite peripheral, connect it to the Zynq PS on ZCU104/PYNQ-style software flow, and demonstrate operation from software control.

The first real demo target is an oscilloscope view through the PYNQ-Z2 onboard ADAU1761 audio codec/headphone output. IFM data is loaded through an AXI BRAM Controller; OFM BRAM/capture is deferred while the output path targets continuous DAC/scope playback.

## Current Project State

The project now has two main RTL paths:

1. Algorithm/debug path:

```text
top_ask
  -> dds_sine
  -> mary_ask_modulator
```

2. AXI package path:

```text
ask_modulator
  -> axi_slave
  -> symbol_bram_player
  -> dds_sine
  -> mary_ask_modulator
  <- IFM BRAM read port
  -> continuous ask_out/dac_data
```

3. PYNQ-Z2 onboard-audio demo path:

```text
ask_audio_top
  -> ask_modulator
  -> audio_i2s_tx
  -> ADAU1761 I2S pins
  -> 3.5 mm audio output / oscilloscope
```

Current RTL compile status:

```text
vlog compile: Errors: 0, Warnings: 0
Top level modules: ask_audio_top, ask_modulator, tb_top, tb_ask_modulator_axi, tb_audio_i2s_tx
```

The AXI testbench runtime could not be executed in this container because Questa `vsim` could not check out a license. The source compiles cleanly; run the simulation locally with a valid license.

The current package top in the workspace is:

```text
hdl/ask_modulator.sv
module ask_modulator
```

Earlier discussion used the name `4ary_ask_modulation.sv`. The current workspace has consolidated that AXI package top into `ask_modulator.sv`.

## Important Files

### RTL

```text
hdl/dds_sine.sv
```

DDS carrier generator. Uses a 32-bit phase accumulator and a sine LUT loaded from `carrier_sine.mem`.

```text
hdl/mary_ask_modulator.sv
```

4-ASK mapper and multiplier. Maps symbols:

```text
00 -> 0%
01 -> ~33%
11 -> ~66%
10 -> 100%
```

```text
hdl/top_ask.sv
```

Simple non-AXI wrapper used by the existing simulation testbench.

```text
hdl/axi_slave.sv
```

AXI4-Lite register block. The Zynq PS is the AXI master; this IP is the AXI slave.

```text
hdl/ask_modulator.sv
```

AXI package top. Handles AXI register wiring, runtime phase tuning, IFM BRAM symbol playback, debug outputs, and DAC-formatted continuous output. OFM BRAM/capture is intentionally not implemented for now.

```text
hdl/symbol_bram_player.sv
```

Reads baseband symbols from IFM BRAM and drives `symbol_in[1:0]` internally for the modulator. Current implementation stores one 2-bit symbol in the low bits of each 32-bit BRAM word and models the IFM side as a synchronous BRAM read port.

```text
hdl/audio_i2s_tx.sv
```

PYNQ-Z2 audio transmitter. Generates codec clocks from the 100 MHz PL clock and serializes mono signed ASK samples into stereo I2S slots for the ADAU1761.

```text
hdl/ask_audio_top.sv
```

PYNQ-Z2 package/demo top. Wraps `ask_modulator`, scales `ask_out`, feeds `audio_i2s_tx`, and exports ADAU1761 pins plus debug signals.

### Simulation

```text
sim/tb/tb_top.sv
```

Self-checking simulation testbench for the non-AXI `top_ask` path. Generates random baseband symbols, dumps CSV files, and compares DUT output against an SV reference model.

```text
sim/tb/axi_master_bfm.sv
```

Small AXI4-Lite master BFM used by the package-top testbench.

```text
sim/tb/tb_ask_modulator_axi.sv
```

Self-checking simulation testbench for the AXI package top. It models IFM BRAM, loads `baseband_symbols.mem`, writes the AXI registers, starts symbol playback, checks symbol sequence and ASK output, and dumps AXI-path CSV files.

```text
sim/tb/tb_audio_i2s_tx.sv
```

Self-checking testbench for the audio transmitter. Checks generated MCLK/BCLK/LRCLK ratios, duplicated left/right sample serialization, and silence when `sample_valid` is low.

```text
sim/tb/carrier_sine.mem
```

Generated sine LUT. Current LUT is 1024 entries, signed 16-bit hex.

```text
sim/work/filelist_rtl.f
sim/work/filelist_tb.f
sim/work/qrun_bash.sh
```

Questa compile/run setup.

### Python

```text
sim/sw/sine_gen_lut.py
```

Generates `carrier_sine.mem`.

```text
sim/sw/baseband_gen.py
```

Generates `sim/tb/baseband_symbols.mem`, one 2-bit 4-ASK symbol per line, and an optional review CSV at `sim/out/baseband_generated.csv`.

```text
sim/sw/reconstruct_ask_waveforms.py
```

Reads simulation CSV files and reconstructs Python golden carrier/ASK waveforms. Generates:

```text
sim/out/python_golden_samples.csv
sim/out/waveform_compare.png
```

```text
sw/ask_demo_data.py
```

Board-independent helper for the PYNQ-Z2 demo. Generates baseband symbols and computes `phase_inc` / `symbol_hold_cycles`.

```text
pynq/ask_audio_demo.py
pynq/adau1761_init.py
notebooks/ask_audio_demo.ipynb
```

PYNQ-side demo driver, ADAU1761 codec init helper, and notebook wrapper.

## Verified Behavior So Far

The sine LUT is used by the DUT.

From previous comparison:

```text
carrier_dut == carrier_sine.mem[phase_addr]
LUT mismatches: 0
```

Python reconstruction comparison:

```text
Max carrier error: 0
Max ASK error: 0
```

The carrier waveform may look continuous in plots because plotting tools connect samples. It is still a clocked/stair-step sampled signal in RTL.

## Core Runtime Controls

### phase_inc

Controls DDS carrier frequency.

```text
phase_inc = round(Fcarrier / Fclk * 2^PHASE_W)
Fcarrier  = phase_inc * Fclk / 2^PHASE_W
```

Current default:

```text
Fclk      = 100 MHz
Fcarrier  = 1 MHz for legacy simulation, 4 kHz for PYNQ-Z2 audio demo
PHASE_W   = 32
phase_inc = 42949673 for 1 MHz, 171799 for 4 kHz
```

### symbol_hold_cycles

Controls how long each IFM BRAM symbol is held by `symbol_bram_player`. In the AXI package path this is an AXI register, not an internally generated baseband source.

```text
Fsymbol = Fclk / symbol_hold_cycles
```

Current debug default:

```text
symbol_hold_cycles = 1000 for fast simulation
symbol_hold_cycles = 1000000 for the 100 sym/s audio demo
```

Because the IFM interface is treated as a synchronous BRAM read port, `symbol_bram_player` internally clamps requested hold values below 3 cycles to 3 cycles. Normal demo/debug values such as 1000 cycles are unaffected.

## AXI Register Map

Current AXI4-Lite register map in `axi_slave.sv`:

| Offset | Register | Description |
|---:|---|---|
| `0x000` | `CTRL` | `bit0 enable`, `bit1 soft_reset pulse`, `bit2 start pulse`, `bit3 loop_enable` |
| `0x004` | `STATUS` | `bit0 enabled`, `bit1 symbol_player_busy`, `bit2 symbol_player_done` |
| `0x008` | `PHASE_INC` | DDS tuning word |
| `0x00C` | `SYMBOL_HOLD_CYCLES` | Clocks per IFM symbol |
| `0x010` | `SYMBOL_COUNT` | Number of IFM symbols to play |
| `0x014` | `CURRENT_SYMBOL` | Debug current symbol |
| `0x018` | `CURRENT_SYMBOL_INDEX` | Debug current IFM symbol index |
| `0x01C` | `CURRENT_CARRIER` | Debug signed carrier sample |
| `0x020` | `CURRENT_ASK_OUT` | Debug signed ASK sample |

## IFM BRAM

IFM is loaded by the PS through an AXI BRAM Controller connected to the write/read port of a true dual-port BRAM. The modulator IP reads the other BRAM port through `symbol_bram_player`.

```text
IFM word width = 32 bits
IFM format     = one symbol per word
word[1:0]      = 4-ASK symbol
word[31:2]     = reserved
```

The package top exposes the modulator-side BRAM read signals:

```text
ifm_bram_en
ifm_bram_addr
ifm_bram_rdata
```

In Vivado, connect these to the second port of a true dual-port BRAM. Connect the first BRAM port to the Zynq PS through an AXI BRAM Controller so Python/PYNQ can load the baseband symbol buffer before starting the modulator.

Recommended first BRAM depth:

```text
4096 x 32 = 4096 symbols
```

For longer runs:

```text
16384 x 32 = 16384 symbols
65536 x 32 = 65536 symbols
```

OFM BRAM is intentionally deferred. The output path is continuous `ask_out/dac_data` for the future DAC/oscilloscope demo.

## Current AXI Simulation Flow

Default testbench top:

```text
tb_ask_modulator_axi
```

Run from `sim/work`:

```text
bash qrun_bash.sh vlg
bash qrun_bash.sh vsm_opt +symbols=1024 +hold=1000
```

Use the legacy non-AXI testbench when needed:

```text
TOP_TB=tb_top bash qrun_bash.sh vsm_opt +symbols=1024 +hold=1000
```

The AXI testbench generates:

```text
sim/out/axi_ifm_samples.csv
sim/out/axi_ifm_baseband_symbols.csv
sim/out/axi_ifm_config.csv
```

Current local verification:

```text
bash qrun_bash.sh vlg
Result: compile clean, 0 errors, 0 warnings
```

Runtime still needs to be run on a machine/session with a valid Questa license.

## External DAC Plan

The generic ASK package top exposes:

```text
ask_out
dac_data
```

`ask_out` is signed two's-complement. `dac_data` is offset-binary style for a future unipolar external DAC path.

The first oscilloscope demo now uses the onboard ADAU1761 audio codec through:

```text
codec_mclk
codec_bclk
codec_lrclk
codec_sdata_o
```

The checked-in PYNQ-Z2 audio XDC snippet is:

```text
constraints/pynq_z2_audio.xdc
```

Still needed before a higher-speed external-DAC demo:

1. Select actual external DAC module/interface.
2. Define DAC pins and XDC constraints.
3. Add SPI/parallel/PWM/PDM DAC interface as needed.
4. Validate voltage range and sample rate.
5. Add analog reconstruction/output filtering if required.

## PYNQ-Z2 Audio Demo Defaults

```text
PL clock           = 100 MHz
MCLK               = 10 MHz
BCLK               = 3.125 MHz
LRCLK/sample rate  = 48.828125 kHz
Carrier            = 4 kHz
Symbol rate        = 100 sym/s
phase_inc          = 171799
symbol_hold_cycles = 1000000
IFM depth          = 4096 x 32
```

MCLK is generated as 10 MHz to match the PYNQ-Z2 base audio clock convention and PYNQ `libaudio` codec configuration path. BCLK/LRCLK keep the planned 48.828125 kS/s frame rate.

## Current Simulation Outputs

Generated CSV/output files:

```text
sim/tb/baseband_symbols.mem
sim/out/tb_config.csv
sim/out/baseband_symbols.csv
sim/out/baseband_generated.csv
sim/out/sim_samples.csv
sim/out/python_golden_samples.csv
sim/out/waveform_compare.png
sim/out/axi_ifm_samples.csv
sim/out/axi_ifm_baseband_symbols.csv
sim/out/axi_ifm_config.csv
```

Typical simulation/reconstruction commands:

```bash
python3 sim/sw/baseband_gen.py --symbols 64 --hold 1000 --seed 0x5EED1234

cd sim/work
bash qrun_bash.sh vlb
bash qrun_bash.sh vlg
bash qrun_bash.sh vsm_opt +seed=123 +symbols=64 +hold=1000

cd ../..
python3 sim/sw/reconstruct_ask_waveforms.py --start-cycle 1 --max-samples 5000
```

PYNQ-Z2 demo data generation:

```bash
python3 sw/ask_demo_data.py \
  --symbols 4096 \
  --carrier-hz 4000 \
  --symbol-rate 100 \
  --mode pattern \
  --pattern 0 1 3 2 \
  --mem sim/tb/baseband_symbols.mem \
  --csv sim/out/pynq_demo_symbols.csv \
  --json sim/out/pynq_demo_config.json
```

PYNQ board demo command after `ask_audio.bit` and `ask_audio.hwh` are copied to the board:

```bash
python3 pynq/ask_audio_demo.py --bit ask_audio.bit
```

## Immediate Next Steps

1. Run the AXI package-top simulation with a valid Questa license.
   - Command: `bash qrun_bash.sh vsm_opt +symbols=1024 +hold=1000`
   - Check for `PASS: ask_modulator AXI IFM BRAM self-check passed`.
   - Review `sim/out/axi_ifm_samples.csv`.

2. Update `sim/sw/reconstruct_ask_waveforms.py` to optionally consume the new AXI-path CSV files.
   - Existing script targets `sim_samples.csv`.
   - New AXI-path source is `axi_ifm_samples.csv`.

3. Add or generate PYNQ Python driver constants.
   - Register offsets.
   - Control bit masks.
   - IFM BRAM symbol loading through AXI BRAM Controller address space.

4. Prepare Vivado IP packaging.
   - Set package top to `ask_audio_top` for the onboard-audio demo.
   - Keep `ask_modulator` packageable as the reusable ASK core.
   - Include `dds_sine.sv`, `mary_ask_modulator.sv`, `axi_slave.sv`, `ask_modulator.sv`.
   - Include `symbol_bram_player.sv`.
   - Include `audio_i2s_tx.sv` and `ask_audio_top.sv`.
   - Include `carrier_sine.mem` as memory initialization source.
   - Confirm `SINE_MEM_FILE` value for Vivado packaging.
   - Expose IFM BRAM read port and connect it to a true-dual-port BRAM.

5. Create Vivado block design.
   - Zynq7 PS.
   - AXI interconnect or SmartConnect.
   - ASK audio AXI peripheral.
   - AXI BRAM Controller for IFM writes from PS.
   - True dual-port IFM BRAM.
   - Route ADAU1761 I2S pins using `constraints/pynq_z2_audio.xdc`.
   - Add codec I2C path through PS I2C over EMIO or AXI IIC connected to `IIC_1_scl_io` / `IIC_1_sda_io`.
   - Optional ILA.

6. PYNQ bring-up.
   - Load `.bit` and `.hwh`.
   - Configure registers with MMIO.
   - Load IFM BRAM through AXI BRAM Controller.
   - Start symbol playback.
   - Observe continuous output through DAC/scope path.

7. External DAC demo path.
   - Select DAC.
   - Add output interface.
   - Add constraints.
   - Verify with oscilloscope.

## Open Questions

1. Which exact external DAC will be used for the oscilloscope demo?
2. Should `ask_modulator` remain the final package top name, or should it be renamed back to a clearer `four_ary_ask_modulation` style name?
3. What IFM BRAM depth should be used in the first ZCU104 block design: `4096 x 32`, `16384 x 32`, or `65536 x 32`?
4. Should IFM remain one symbol per 32-bit word for clarity, or should a later version pack multiple 2-bit symbols per word for memory efficiency?
