#!/usr/bin/env python3
"""Generate a sine lookup table for a SystemVerilog DDS carrier.

Default output:
    ../tb/carrier_sine.mem

The default format is one 16-bit two's-complement hex value per line, which is
ready for a SystemVerilog ROM initialized with $readmemh.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
from typing import List


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = SCRIPT_DIR.parent / "tb" / "carrier_sine.mem"


def positive_int(value: str) -> int:
    parsed = int(value, 0)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def sample_width(value: str) -> int:
    parsed = positive_int(value)
    if parsed < 2:
        raise argparse.ArgumentTypeError("sample width must be at least 2 bits")
    return parsed


def amplitude_value(value: str) -> float:
    parsed = float(value)
    if not 0.0 <= parsed <= 1.0:
        raise argparse.ArgumentTypeError("amplitude must be in the range [0.0, 1.0]")
    return parsed


def is_power_of_two(value: int) -> bool:
    return value > 0 and (value & (value - 1)) == 0


def signed_sine_samples(
    *,
    depth: int,
    width: int,
    amplitude: float,
    phase_deg: float,
) -> List[int]:
    """Return signed integer samples in the range +/-((2**(width - 1)) - 1)."""
    max_signed = (1 << (width - 1)) - 1
    phase_rad = math.radians(phase_deg)
    samples: List[int] = []

    for index in range(depth):
        angle = (2.0 * math.pi * index / depth) + phase_rad
        value = round(math.sin(angle) * amplitude * max_signed)
        value = max(-max_signed, min(max_signed, int(value)))
        samples.append(value)

    return samples


def offset_binary_samples(
    *,
    depth: int,
    width: int,
    amplitude: float,
    phase_deg: float,
) -> List[int]:
    """Return unsigned offset-binary samples in the range 0..((2**width) - 1)."""
    max_unsigned = (1 << width) - 1
    phase_rad = math.radians(phase_deg)
    samples: List[int] = []

    for index in range(depth):
        angle = (2.0 * math.pi * index / depth) + phase_rad
        normalized = (math.sin(angle) * amplitude) + 1.0
        value = round(normalized * max_unsigned / 2.0)
        value = max(0, min(max_unsigned, int(value)))
        samples.append(value)

    return samples


def twos_complement(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def format_sample(value: int, *, width: int, encoding: str, radix: str) -> str:
    if encoding == "signed":
        encoded = twos_complement(value, width)
    else:
        encoded = value

    if radix == "hex":
        digits = (width + 3) // 4
        return f"{encoded:0{digits}X}"
    if radix == "bin":
        return f"{encoded:0{width}b}"
    return str(value)


def write_mem_file(
    *,
    samples: List[int],
    width: int,
    encoding: str,
    radix: str,
    out_path: Path,
) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii", newline="\n") as mem_file:
        for sample in samples:
            mem_file.write(format_sample(sample, width=width, encoding=encoding, radix=radix))
            mem_file.write("\n")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a sine LUT .mem file for SystemVerilog $readmemh/$readmemb.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--depth",
        type=positive_int,
        default=1024,
        help="number of LUT samples per sine period",
    )
    parser.add_argument(
        "--width",
        type=sample_width,
        default=16,
        help="sample width in bits",
    )
    parser.add_argument(
        "--amplitude",
        type=amplitude_value,
        default=1.0,
        help="full-scale multiplier",
    )
    parser.add_argument(
        "--phase-deg",
        type=float,
        default=0.0,
        help="initial phase offset in degrees",
    )
    parser.add_argument(
        "--encoding",
        choices=("signed", "offset-binary"),
        default="signed",
        help="signed two's-complement carrier or unsigned DAC-style samples",
    )
    parser.add_argument(
        "--radix",
        choices=("hex", "bin", "decimal"),
        default="hex",
        help="text format written to the .mem file",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help="output .mem path",
    )
    parser.add_argument(
        "--allow-non-power-of-two",
        action="store_true",
        help="skip the DDS-friendly power-of-two depth check",
    )
    parser.add_argument(
        "--preview",
        type=positive_int,
        default=8,
        help="number of generated samples to print",
    )
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()

    if not args.allow_non_power_of_two and not is_power_of_two(args.depth):
        raise SystemExit(
            f"error: --depth={args.depth} is not a power of two; "
            "use --allow-non-power-of-two to override"
        )

    if args.encoding == "signed":
        samples = signed_sine_samples(
            depth=args.depth,
            width=args.width,
            amplitude=args.amplitude,
            phase_deg=args.phase_deg,
        )
    else:
        samples = offset_binary_samples(
            depth=args.depth,
            width=args.width,
            amplitude=args.amplitude,
            phase_deg=args.phase_deg,
        )

    out_path = args.out.expanduser().resolve()
    write_mem_file(
        samples=samples,
        width=args.width,
        encoding=args.encoding,
        radix=args.radix,
        out_path=out_path,
    )

    print(f"Wrote {len(samples)} samples to {out_path}")
    print(f"width={args.width} encoding={args.encoding} radix={args.radix}")
    print(f"sample range: min={min(samples)} max={max(samples)}")
    if args.preview:
        print("preview:")
        for index, sample in enumerate(samples[: args.preview]):
            text = format_sample(sample, width=args.width, encoding=args.encoding, radix=args.radix)
            print(f"  {index:4d}: {text} ({sample})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
