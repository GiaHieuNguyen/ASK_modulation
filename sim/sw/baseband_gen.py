#!/usr/bin/env python3
"""Generate baseband 4-ASK symbols for simulation.

Default output:
    ../tb/baseband_symbols.mem

The .mem file stores one 2-bit symbol per line in hex:
    0 -> 2'b00
    1 -> 2'b01
    2 -> 2'b10
    3 -> 2'b11
"""

from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path
from typing import Iterable, List


SCRIPT_DIR = Path(__file__).resolve().parent
SIM_DIR = SCRIPT_DIR.parent
DEFAULT_MEM = SIM_DIR / "tb" / "baseband_symbols.mem"
DEFAULT_CSV = SIM_DIR / "out" / "baseband_generated.csv"


def positive_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def nonnegative_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be greater than or equal to zero")
    return parsed


def parse_pattern(pattern: str) -> List[int]:
    tokens = [token.strip() for token in pattern.replace(",", " ").split()]
    if not tokens:
        raise argparse.ArgumentTypeError("pattern must contain at least one symbol")

    symbols: List[int] = []
    for token in tokens:
        symbol = int(token, 0)
        if symbol < 0 or symbol > 3:
            raise argparse.ArgumentTypeError("4-ASK symbols must be in the range 0..3")
        symbols.append(symbol)
    return symbols


def random_symbols(count: int, seed: int) -> List[int]:
    generator = random.Random(seed)
    return [generator.randrange(4) for _ in range(count)]


def pattern_symbols(count: int, pattern: Iterable[int]) -> List[int]:
    pattern_list = list(pattern)
    return [pattern_list[index % len(pattern_list)] for index in range(count)]


def write_mem(path: Path, symbols: Iterable[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as mem_file:
        for symbol in symbols:
            mem_file.write(f"{symbol:X}\n")


def write_csv(path: Path, symbols: Iterable[int], hold_cycles: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(["symbol_index", "start_cycle", "end_cycle", "symbol_dec", "symbol_bin"])
        for index, symbol in enumerate(symbols):
            start_cycle = (index * hold_cycles) + 1
            end_cycle = start_cycle + hold_cycles - 1
            writer.writerow([index, start_cycle, end_cycle, symbol, f"{symbol:02b}"])


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a baseband symbol .mem file for the ASK simulation testbench.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--symbols", type=positive_int, default=1024, help="number of symbols")
    parser.add_argument("--hold", type=positive_int, default=1000, help="cycles per symbol, for CSV annotation")
    parser.add_argument("--seed", type=nonnegative_int, default=0x5EED1234, help="random seed")
    parser.add_argument(
        "--mode",
        choices=("random", "pattern"),
        default="random",
        help="baseband generation mode",
    )
    parser.add_argument(
        "--pattern",
        type=parse_pattern,
        default=parse_pattern("0 1 3 2"),
        help="repeating symbol pattern used when --mode pattern",
    )
    parser.add_argument("--out", type=Path, default=DEFAULT_MEM, help="output .mem path")
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV, help="optional review CSV path")
    parser.add_argument("--no-csv", action="store_true", help="do not write the review CSV")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()

    if args.mode == "random":
        symbols = random_symbols(args.symbols, args.seed)
    else:
        symbols = pattern_symbols(args.symbols, args.pattern)

    out_path = args.out.expanduser().resolve()
    write_mem(out_path, symbols)

    print(f"Wrote {len(symbols)} symbols to {out_path}")
    print(f"mode={args.mode} seed={args.seed} hold={args.hold}")
    print("preview:", " ".join(f"{symbol:X}" for symbol in symbols[:16]))

    if not args.no_csv:
        csv_path = args.csv.expanduser().resolve()
        write_csv(csv_path, symbols, args.hold)
        print(f"Wrote review CSV to {csv_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
