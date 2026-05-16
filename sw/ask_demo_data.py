#!/usr/bin/env python3
"""Generate symbols and register settings for the PYNQ-Z2 ASK audio demo."""

from __future__ import annotations

import argparse
import csv
import json
import random
from pathlib import Path
from typing import Iterable, List, Sequence


DEFAULT_CLK_HZ = 100_000_000
DEFAULT_PHASE_W = 32
DEFAULT_SYMBOLS = 4096
DEFAULT_CARRIER_HZ = 4000.0
DEFAULT_SYMBOL_RATE = 100.0
DEFAULT_PATTERN = [0, 1, 3, 2]


def positive_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def symbol_value(value: str) -> int:
    parsed = int(value, 0)
    if parsed < 0 or parsed > 3:
        raise argparse.ArgumentTypeError("4-ASK symbols must be in the range 0..3")
    return parsed


def phase_inc_for_frequency(carrier_hz: float, clk_hz: int, phase_w: int = DEFAULT_PHASE_W) -> int:
    return int(round((carrier_hz / clk_hz) * (1 << phase_w)))


def hold_cycles_for_symbol_rate(symbol_rate: float, clk_hz: int) -> int:
    return max(1, int(round(clk_hz / symbol_rate)))


def random_symbols(count: int, seed: int) -> List[int]:
    generator = random.Random(seed)
    return [generator.randrange(4) for _ in range(count)]


def pattern_symbols(count: int, pattern: Iterable[int]) -> List[int]:
    pattern_list = list(pattern)
    if not pattern_list:
        raise ValueError("pattern must contain at least one symbol")
    return [pattern_list[index % len(pattern_list)] for index in range(count)]


def constant_symbols(count: int, symbol: int) -> List[int]:
    if symbol < 0 or symbol > 3:
        raise ValueError("4-ASK symbols must be in the range 0..3")
    return [symbol for _ in range(count)]


def write_mem(path: Path, symbols: Sequence[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as mem_file:
        for symbol in symbols:
            mem_file.write(f"{symbol:X}\n")


def write_csv(path: Path, symbols: Sequence[int], hold_cycles: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(["symbol_index", "start_cycle", "end_cycle", "symbol_dec", "symbol_bin", "ifm_word_hex"])
        for index, symbol in enumerate(symbols):
            start_cycle = (index * hold_cycles) + 1
            end_cycle = start_cycle + hold_cycles - 1
            writer.writerow([index, start_cycle, end_cycle, symbol, f"{symbol:02b}", f"{symbol:08X}"])


def write_json(path: Path, config: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as json_file:
        json.dump(config, json_file, indent=2)
        json_file.write("\n")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate symbols and register settings for the PYNQ-Z2 ASK audio demo.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--clk-hz", type=positive_int, default=DEFAULT_CLK_HZ, help="PL clock frequency")
    parser.add_argument("--phase-w", type=positive_int, default=DEFAULT_PHASE_W, help="DDS phase accumulator width")
    parser.add_argument("--symbols", type=positive_int, default=DEFAULT_SYMBOLS, help="number of symbols")
    parser.add_argument("--carrier-hz", type=positive_float, default=DEFAULT_CARRIER_HZ, help="carrier frequency")
    parser.add_argument("--symbol-rate", type=positive_float, default=DEFAULT_SYMBOL_RATE, help="symbol rate")
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5EED1234, help="random seed")
    parser.add_argument("--mode", choices=("pattern", "random", "constant"), default="pattern", help="symbol mode")
    parser.add_argument("--pattern", nargs="+", type=symbol_value, default=DEFAULT_PATTERN, help="pattern symbols")
    parser.add_argument("--constant-symbol", type=symbol_value, default=2, help="symbol used with --mode constant")
    parser.add_argument("--mem", type=Path, default=Path("sim/tb/baseband_symbols.mem"), help="output .mem path")
    parser.add_argument("--csv", type=Path, default=Path("sim/out/pynq_demo_symbols.csv"), help="output CSV path")
    parser.add_argument("--json", type=Path, default=Path("sim/out/pynq_demo_config.json"), help="output JSON path")
    parser.add_argument("--no-mem", action="store_true", help="do not write .mem")
    parser.add_argument("--no-csv", action="store_true", help="do not write CSV")
    parser.add_argument("--no-json", action="store_true", help="do not write JSON")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()

    if args.mode == "pattern":
        symbols = pattern_symbols(args.symbols, args.pattern)
    elif args.mode == "random":
        symbols = random_symbols(args.symbols, args.seed)
    else:
        symbols = constant_symbols(args.symbols, args.constant_symbol)

    phase_inc = phase_inc_for_frequency(args.carrier_hz, args.clk_hz, args.phase_w)
    hold_cycles = hold_cycles_for_symbol_rate(args.symbol_rate, args.clk_hz)

    config = {
        "clk_hz": args.clk_hz,
        "phase_w": args.phase_w,
        "carrier_hz": args.carrier_hz,
        "symbol_rate": args.symbol_rate,
        "phase_inc": phase_inc,
        "symbol_hold_cycles": hold_cycles,
        "symbol_count": len(symbols),
        "mode": args.mode,
        "pattern": args.pattern,
        "constant_symbol": args.constant_symbol,
        "seed": args.seed,
        "symbols": symbols,
    }

    if not args.no_mem:
        write_mem(args.mem, symbols)
        print(f"Wrote {len(symbols)} symbols to {args.mem}")
    if not args.no_csv:
        write_csv(args.csv, symbols, hold_cycles)
        print(f"Wrote symbol review CSV to {args.csv}")
    if not args.no_json:
        write_json(args.json, config)
        print(f"Wrote demo config JSON to {args.json}")

    print(f"phase_inc={phase_inc}")
    print(f"symbol_hold_cycles={hold_cycles}")
    print("preview:", " ".join(f"{symbol:X}" for symbol in symbols[:16]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
