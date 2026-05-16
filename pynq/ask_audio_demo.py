#!/usr/bin/env python3
"""PYNQ-Z2 ASK audio demo driver.

Copy this file, adau1761_init.py, ask_audio.bit, and ask_audio.hwh to the same
directory on the PYNQ-Z2, then run:

    python3 ask_audio_demo.py --bit ask_audio.bit
"""

from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence

try:
    from adau1761_init import configure_adau1761
except ImportError:  # pragma: no cover - used when imported as a package
    from .adau1761_init import configure_adau1761


DEFAULT_CLK_HZ = 100_000_000
DEFAULT_PHASE_W = 32
DEFAULT_SYMBOL_COUNT = 4096
DEFAULT_CARRIER_HZ = 4000.0
DEFAULT_SYMBOL_RATE = 100.0
DEFAULT_PATTERN = [0, 1, 3, 2]


REG_CTRL = 0x000
REG_STATUS = 0x004
REG_PHASE_INC = 0x008
REG_SYMBOL_HOLD = 0x00C
REG_SYMBOL_COUNT = 0x010
REG_CURRENT_SYMBOL = 0x014
REG_CURRENT_SYMBOL_INDEX = 0x018
REG_CURRENT_CARRIER = 0x01C
REG_CURRENT_ASK = 0x020

CTRL_ENABLE = 1 << 0
CTRL_SOFT_RESET = 1 << 1
CTRL_START = 1 << 2
CTRL_LOOP_ENABLE = 1 << 3

STATUS_ENABLE = 1 << 0
STATUS_PLAYER_BUSY = 1 << 1
STATUS_PLAYER_DONE = 1 << 2


def phase_inc_for_frequency(carrier_hz: float, clk_hz: int = DEFAULT_CLK_HZ, phase_w: int = DEFAULT_PHASE_W) -> int:
    return int(round((carrier_hz / clk_hz) * (1 << phase_w)))


def hold_cycles_for_symbol_rate(symbol_rate: float, clk_hz: int = DEFAULT_CLK_HZ) -> int:
    return max(1, int(round(clk_hz / symbol_rate)))


def pattern_symbols(count: int, pattern: Iterable[int] = DEFAULT_PATTERN) -> List[int]:
    pattern_list = [int(symbol) & 0x3 for symbol in pattern]
    if not pattern_list:
        raise ValueError("pattern must contain at least one symbol")
    return [pattern_list[index % len(pattern_list)] for index in range(count)]


def random_symbols(count: int, seed: int = 0x5EED1234) -> List[int]:
    generator = random.Random(seed)
    return [generator.randrange(4) for _ in range(count)]


def constant_symbols(count: int, symbol: int = 2) -> List[int]:
    return [int(symbol) & 0x3 for _ in range(count)]


def load_symbols_from_json(path: Path) -> tuple[list[int], dict]:
    with path.open() as json_file:
        config = json.load(json_file)
    symbols = [int(symbol) & 0x3 for symbol in config["symbols"]]
    return symbols, config


def _iter_description_maps(description: object) -> list[tuple[str, dict]]:
    maps = [("ip_dict", getattr(description, "ip_dict", {}))]
    mem_dict = getattr(description, "mem_dict", None)
    if mem_dict:
        maps.append(("mem_dict", mem_dict))
    return maps


def _meta_phys_addr(meta: dict) -> int:
    return int(meta.get("phys_addr", meta.get("base_address", 0)))


def _meta_addr_range(meta: dict) -> int:
    return int(meta.get("addr_range", meta.get("range", 0)))


def list_addressable_ips(description: object) -> list[dict]:
    rows = []
    for map_name, addr_map in _iter_description_maps(description):
        for name, meta in addr_map.items():
            rows.append(
                {
                    "map": map_name,
                    "name": name,
                    "phys_addr": _meta_phys_addr(meta),
                    "addr_range": _meta_addr_range(meta),
                    "type": meta.get("type", ""),
                }
            )
    return rows


def print_addressable_ips(description: object) -> None:
    rows = list_addressable_ips(description)
    if not rows:
        print("No addressable IPs found in overlay.ip_dict")
        return

    print("Addressable entries found in the overlay:")
    for row in rows:
        print(
            f"  {row['map']}:{row['name']}: "
            f"base=0x{row['phys_addr']:08X}, "
            f"range=0x{row['addr_range']:X}, "
            f"type={row['type']}"
        )


def _find_ip(description: object, candidates: Sequence[str]) -> tuple[str, dict]:
    lowered = []
    available_names = []
    for _map_name, addr_map in _iter_description_maps(description):
        for name, meta in addr_map.items():
            lowered.append((name.lower(), name, meta))
            available_names.append(name)

    for candidate in candidates:
        candidate_lower = candidate.lower()
        for lowered_name, name, meta in lowered:
            if candidate_lower in lowered_name:
                return name, meta

    available = ", ".join(available_names) if available_names else "<none>"
    raise KeyError(
        f"Could not find IP matching any of: {', '.join(candidates)}. "
        f"Available addressable entries: {available}"
    )


def _get_addressable_entry(description: object, name: str) -> dict:
    for _map_name, addr_map in _iter_description_maps(description):
        if name in addr_map:
            return addr_map[name]
    available = []
    for _map_name, addr_map in _iter_description_maps(description):
        available.extend(addr_map.keys())
    raise KeyError(f"Could not find addressable entry '{name}'. Available entries: {', '.join(available)}")


def summarize_debug_capture(samples: Sequence[dict]) -> dict:
    if not samples:
        raise ValueError("samples must not be empty")

    duration_s = samples[-1]["time_s"] - samples[0]["time_s"]
    interval_s = duration_s / (len(samples) - 1) if len(samples) > 1 else 0.0
    symbol_indices = [sample["current_symbol_index"] for sample in samples]
    return {
        "samples": len(samples),
        "duration_s": duration_s,
        "mean_poll_interval_s": interval_s,
        "mean_poll_rate_hz": (1.0 / interval_s) if interval_s > 0 else 0.0,
        "first_symbol_index": min(symbol_indices),
        "last_symbol_index": max(symbol_indices),
        "symbol_index_span": max(symbol_indices) - min(symbol_indices),
    }


def plot_debug_capture(samples: Sequence[dict], *, title: str = "ASK RTL hardware debug capture"):
    if not samples:
        raise ValueError("samples must not be empty")

    import matplotlib.pyplot as plt

    time_s = [sample["time_s"] for sample in samples]
    symbols = [sample["current_symbol"] for sample in samples]
    expected_symbols = [
        sample["expected_symbol"] for sample in samples
        if "expected_symbol" in sample and sample["expected_symbol"] is not None
    ]
    symbol_indices = [sample["current_symbol_index"] for sample in samples]
    carriers = [sample["current_carrier"] for sample in samples]
    ask_values = [sample["current_ask"] for sample in samples]
    summary = summarize_debug_capture(samples)

    fig, axes = plt.subplots(4, 1, sharex=True, figsize=(13, 9))
    fig.suptitle(
        f"{title}\n"
        f"{summary['samples']} AXI polls, "
        f"{summary['duration_s']:.3f} s capture, "
        f"{summary['mean_poll_rate_hz']:.1f} polls/s"
    )

    axes[0].step(time_s, symbols, where="post", linewidth=1.6)
    if len(expected_symbols) == len(samples):
        axes[0].step(time_s, expected_symbols, where="post", linestyle="--", linewidth=1.1)
        axes[0].legend(["RTL current_symbol register", "PS BRAM readback at current index"], loc="upper right")
    axes[0].set_ylabel("Symbol code\n(2-bit)")
    axes[0].set_yticks([0, 1, 2, 3])
    axes[0].set_ylim(-0.25, 3.25)
    axes[0].grid(True, alpha=0.35)

    axes[1].plot(time_s, symbol_indices, linewidth=1.4)
    axes[1].set_ylabel("IFM BRAM\nword index")
    axes[1].grid(True, alpha=0.35)

    axes[2].plot(time_s, carriers, linewidth=1.2)
    axes[2].set_ylabel("Carrier sample\n(signed 16-bit code)")
    axes[2].grid(True, alpha=0.35)

    axes[3].plot(time_s, ask_values, linewidth=1.2)
    axes[3].set_ylabel("ASK output sample\n(signed 16-bit code)")
    axes[3].set_xlabel("Software polling time after capture start (s)")
    axes[3].grid(True, alpha=0.35)

    fig.tight_layout(rect=(0, 0, 1, 0.95))
    return fig, axes


def save_debug_capture_csv(samples: Sequence[dict], path: str | Path) -> None:
    import csv

    fieldnames = [
        "sample",
        "time_s",
        "status_raw",
        "enabled",
        "busy",
        "done",
        "current_symbol",
        "expected_symbol",
        "current_symbol_index",
        "current_carrier",
        "current_ask",
    ]
    with Path(path).open("w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for sample in samples:
            writer.writerow({field: sample.get(field) for field in fieldnames})


@dataclass
class AskStatus:
    enabled: bool
    busy: bool
    done: bool
    raw: int


class AskAudioDemo:
    def __init__(
        self,
        bitfile: str | Path = "ask_audio.bit",
        *,
        ask_ip_name: Optional[str] = None,
        ifm_bram_ip_name: Optional[str] = None,
        ifm_bram_base_addr: Optional[int] = None,
        ifm_bram_addr_range: int = 0x2000,
        clk_hz: int = DEFAULT_CLK_HZ,
        phase_w: int = DEFAULT_PHASE_W,
        init_codec: bool = True,
        iic_index: int = 1,
    ) -> None:
        from pynq import MMIO, Overlay

        self.clk_hz = clk_hz
        self.phase_w = phase_w
        self.overlay = Overlay(str(bitfile))

        if ask_ip_name is None:
            ask_ip_name, ask_meta = _find_ip(self.overlay, ("ask_audio_top", "ask_modulator"))
        else:
            ask_meta = _get_addressable_entry(self.overlay, ask_ip_name)

        if ifm_bram_base_addr is not None:
            ifm_bram_ip_name = f"manual_0x{int(ifm_bram_base_addr):08X}"
            ifm_meta = {
                "phys_addr": int(ifm_bram_base_addr),
                "addr_range": int(ifm_bram_addr_range),
            }
        elif ifm_bram_ip_name is None:
            ifm_bram_ip_name, ifm_meta = _find_ip(self.overlay, ("axi_bram_ctrl", "bram_ctrl", "ifm"))
        else:
            ifm_meta = _get_addressable_entry(self.overlay, ifm_bram_ip_name)

        self.ask_ip_name = ask_ip_name
        self.ifm_bram_ip_name = ifm_bram_ip_name
        self.ifm_bram_addr_range = _meta_addr_range(ifm_meta)
        self.ifm_bram_word_capacity = self.ifm_bram_addr_range // 4
        self.ask_mmio = MMIO(_meta_phys_addr(ask_meta), _meta_addr_range(ask_meta))
        self.ifm_mmio = MMIO(_meta_phys_addr(ifm_meta), _meta_addr_range(ifm_meta))
        self.codec_result = None

        if init_codec:
            self.codec_result = configure_adau1761(iic_index=iic_index)

    def write_reg(self, offset: int, value: int) -> None:
        self.ask_mmio.write(offset, int(value) & 0xFFFFFFFF)

    def read_reg(self, offset: int) -> int:
        return int(self.ask_mmio.read(offset)) & 0xFFFFFFFF

    def soft_reset(self) -> None:
        self.write_reg(REG_CTRL, CTRL_SOFT_RESET)

    def stop(self) -> None:
        self.write_reg(REG_CTRL, 0)

    def _check_symbol_range(self, start: int, count: int) -> None:
        if start < 0 or count < 0:
            raise ValueError("start and count must be non-negative")
        if start + count > self.ifm_bram_word_capacity:
            raise ValueError(
                f"IFM BRAM access out of range: start={start}, count={count}, "
                f"capacity={self.ifm_bram_word_capacity} 32-bit words"
            )

    def read_symbol(self, index: int) -> int:
        self._check_symbol_range(index, 1)
        return int(self.ifm_mmio.read(index * 4)) & 0x3

    def read_symbols(self, count: int, *, start: int = 0) -> list[int]:
        self._check_symbol_range(start, count)
        return [self.read_symbol(index) for index in range(start, start + count)]

    def verify_symbols(self, symbols: Sequence[int], *, start: int = 0, max_errors: int = 16) -> dict:
        self._check_symbol_range(start, len(symbols))
        mismatches = []
        for offset, expected in enumerate(symbols):
            index = start + offset
            actual = self.read_symbol(index)
            expected_symbol = int(expected) & 0x3
            if actual != expected_symbol:
                mismatches.append(
                    {
                        "index": index,
                        "expected": expected_symbol,
                        "actual": actual,
                    }
                )
                if len(mismatches) >= max_errors:
                    break

        return {
            "checked": len(symbols),
            "passed": not mismatches,
            "mismatch_count_limited": len(mismatches),
            "mismatches": mismatches,
        }

    def load_symbols(self, symbols: Sequence[int], *, verify: bool = False) -> Optional[dict]:
        if len(symbols) > self.ifm_bram_word_capacity:
            raise ValueError(
                f"Too many symbols for IFM BRAM: requested {len(symbols)} words, "
                f"but address range 0x{self.ifm_bram_addr_range:X} only holds "
                f"{self.ifm_bram_word_capacity} 32-bit words. "
                "Reduce SYMBOL_COUNT or increase the AXI BRAM address range/depth."
            )
        for index, symbol in enumerate(symbols):
            self.ifm_mmio.write(index * 4, int(symbol) & 0x3)
        self.symbol_count = len(symbols)
        if verify:
            return self.verify_symbols(symbols)
        return None

    def configure(
        self,
        *,
        carrier_hz: float = DEFAULT_CARRIER_HZ,
        symbol_rate: float = DEFAULT_SYMBOL_RATE,
        symbol_count: Optional[int] = None,
        phase_inc: Optional[int] = None,
        symbol_hold_cycles: Optional[int] = None,
    ) -> dict:
        if phase_inc is None:
            phase_inc = phase_inc_for_frequency(carrier_hz, self.clk_hz, self.phase_w)
        if symbol_hold_cycles is None:
            symbol_hold_cycles = hold_cycles_for_symbol_rate(symbol_rate, self.clk_hz)
        if symbol_count is None:
            symbol_count = getattr(self, "symbol_count", DEFAULT_SYMBOL_COUNT)

        self.write_reg(REG_PHASE_INC, phase_inc)
        self.write_reg(REG_SYMBOL_HOLD, symbol_hold_cycles)
        self.write_reg(REG_SYMBOL_COUNT, symbol_count)

        self.last_config = {
            "carrier_hz": carrier_hz,
            "symbol_rate": symbol_rate,
            "phase_inc": phase_inc,
            "symbol_hold_cycles": symbol_hold_cycles,
            "symbol_count": symbol_count,
        }
        return dict(self.last_config)

    def start(self, *, loop: bool = True) -> None:
        ctrl = CTRL_ENABLE | CTRL_START
        if loop:
            ctrl |= CTRL_LOOP_ENABLE
        self.write_reg(REG_CTRL, ctrl)

    def status(self) -> AskStatus:
        raw = self.read_reg(REG_STATUS)
        return AskStatus(
            enabled=bool(raw & STATUS_ENABLE),
            busy=bool(raw & STATUS_PLAYER_BUSY),
            done=bool(raw & STATUS_PLAYER_DONE),
            raw=raw,
        )

    def read_debug(self) -> dict:
        return {
            "status": self.status(),
            "current_symbol": self.read_reg(REG_CURRENT_SYMBOL) & 0x3,
            "current_symbol_index": self.read_reg(REG_CURRENT_SYMBOL_INDEX),
            "current_carrier": self._signed32_to_int(self.read_reg(REG_CURRENT_CARRIER)),
            "current_ask": self._signed32_to_int(self.read_reg(REG_CURRENT_ASK)),
        }

    def capture_debug_samples(
        self,
        count: int = 512,
        *,
        interval_s: float = 0.001,
        include_expected_symbol: bool = True,
    ) -> list[dict]:
        if count <= 0:
            raise ValueError("count must be positive")
        if interval_s < 0:
            raise ValueError("interval_s must be non-negative")

        samples = []
        start_time = time.monotonic()
        for sample_index in range(count):
            debug = self.read_debug()
            status = debug["status"]
            symbol_index = debug["current_symbol_index"]
            expected_symbol = None
            if include_expected_symbol and symbol_index < self.ifm_bram_word_capacity:
                expected_symbol = self.read_symbol(symbol_index)

            samples.append(
                {
                    "sample": sample_index,
                    "time_s": time.monotonic() - start_time,
                    "status_raw": status.raw,
                    "enabled": status.enabled,
                    "busy": status.busy,
                    "done": status.done,
                    "current_symbol": debug["current_symbol"],
                    "expected_symbol": expected_symbol,
                    "current_symbol_index": symbol_index,
                    "current_carrier": debug["current_carrier"],
                    "current_ask": debug["current_ask"],
                }
            )
            if interval_s > 0 and sample_index != count - 1:
                time.sleep(interval_s)
        return samples

    @staticmethod
    def _signed32_to_int(value: int) -> int:
        value &= 0xFFFFFFFF
        return value - (1 << 32) if value & (1 << 31) else value


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the PYNQ-Z2 ASK audio oscilloscope demo")
    parser.add_argument("--bit", default="ask_audio.bit", help="overlay bitstream")
    parser.add_argument("--config-json", type=Path, help="optional JSON generated by sw/ask_demo_data.py")
    parser.add_argument("--symbols", type=int, default=DEFAULT_SYMBOL_COUNT)
    parser.add_argument("--carrier-hz", type=float, default=DEFAULT_CARRIER_HZ)
    parser.add_argument("--symbol-rate", type=float, default=DEFAULT_SYMBOL_RATE)
    parser.add_argument("--mode", choices=("pattern", "random", "constant"), default="pattern")
    parser.add_argument("--pattern", nargs="+", type=lambda value: int(value, 0), default=DEFAULT_PATTERN)
    parser.add_argument("--constant-symbol", type=lambda value: int(value, 0), default=2)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5EED1234)
    parser.add_argument("--no-loop", action="store_true")
    parser.add_argument("--no-codec-init", action="store_true")
    parser.add_argument("--list-ips", action="store_true", help="load the overlay, print addressable IP names, then exit")
    parser.add_argument("--ask-ip-name")
    parser.add_argument("--ifm-bram-ip-name")
    parser.add_argument("--ifm-bram-base", type=lambda value: int(value, 0), help="manual IFM AXI BRAM base address")
    parser.add_argument("--ifm-bram-range", type=lambda value: int(value, 0), default=0x2000, help="manual IFM AXI BRAM range")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()

    if args.list_ips:
        from pynq import Overlay

        overlay = Overlay(str(args.bit))
        print_addressable_ips(overlay)
        return 0

    if args.config_json:
        symbols, config = load_symbols_from_json(args.config_json)
        carrier_hz = float(config.get("carrier_hz", args.carrier_hz))
        symbol_rate = float(config.get("symbol_rate", args.symbol_rate))
        phase_inc = int(config.get("phase_inc", phase_inc_for_frequency(carrier_hz)))
        symbol_hold_cycles = int(config.get("symbol_hold_cycles", hold_cycles_for_symbol_rate(symbol_rate)))
    else:
        if args.mode == "pattern":
            symbols = pattern_symbols(args.symbols, args.pattern)
        elif args.mode == "random":
            symbols = random_symbols(args.symbols, args.seed)
        else:
            symbols = constant_symbols(args.symbols, args.constant_symbol)
        carrier_hz = args.carrier_hz
        symbol_rate = args.symbol_rate
        phase_inc = phase_inc_for_frequency(carrier_hz)
        symbol_hold_cycles = hold_cycles_for_symbol_rate(symbol_rate)

    demo = AskAudioDemo(
        args.bit,
        ask_ip_name=args.ask_ip_name,
        ifm_bram_ip_name=args.ifm_bram_ip_name,
        ifm_bram_base_addr=args.ifm_bram_base,
        ifm_bram_addr_range=args.ifm_bram_range,
        init_codec=not args.no_codec_init,
    )
    demo.stop()
    demo.load_symbols(symbols)
    config = demo.configure(
        carrier_hz=carrier_hz,
        symbol_rate=symbol_rate,
        symbol_count=len(symbols),
        phase_inc=phase_inc,
        symbol_hold_cycles=symbol_hold_cycles,
    )
    demo.start(loop=not args.no_loop)

    print("ASK audio demo started")
    print("ask_ip:", demo.ask_ip_name)
    print("ifm_bram_ip:", demo.ifm_bram_ip_name)
    print("codec:", demo.codec_result)
    print("config:", config)
    print("status:", demo.status())
    print("debug:", demo.read_debug())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
