"""ADAU1761 initialization helper for the PYNQ-Z2 ASK audio demo.

The preferred path reuses PYNQ's shipped libaudio.so configuration routines.
Those routines configure the PYNQ-Z2 ADAU1761 over Linux I2C and are the most
reliable option across PYNQ images.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


DEFAULT_IIC_INDEX = 1
DEFAULT_SAMPLE_RATE_HZ = 48_828


@dataclass(frozen=True)
class CodecConfigResult:
    method: str
    iic_index: int
    sample_rate_hz: int
    volume: float


def _configure_with_pynq_libaudio(iic_index: int) -> None:
    import cffi
    import pynq.lib.audio as pynq_audio

    lib_path = Path(pynq_audio.__file__).resolve().parent / "libaudio.so"
    if not lib_path.exists():
        raise FileNotFoundError(f"Cannot find PYNQ libaudio.so at {lib_path}")

    ffi = cffi.FFI()
    ffi.cdef("void config_audio_pll(int iic_index);")
    ffi.cdef("void config_audio_codec(int iic_index);")
    libaudio = ffi.dlopen(str(lib_path))
    libaudio.config_audio_pll(iic_index)
    libaudio.config_audio_codec(iic_index)


def _configure_with_direct_i2c(iic_index: int) -> None:
    """Best-effort fallback for images where PYNQ libaudio is unavailable.

    This intentionally fails with a precise message for now. The ADAU1761 bring-up
    sequence is board-specific and should not be approximated blindly; the PYNQ
    libaudio path above is the validated source for the PYNQ-Z2.
    """

    try:
        import smbus  # type: ignore  # noqa: F401
    except ImportError as exc:
        raise RuntimeError(
            "PYNQ libaudio initialization failed and no smbus module is installed. "
            "Install smbus/smbus2 or use a PYNQ image that includes pynq.lib.audio."
        ) from exc

    raise NotImplementedError(
        "Direct ADAU1761 I2C fallback is not enabled yet. Use the PYNQ libaudio "
        "path, or add the exact PYNQ-Z2 ADAU1761 register sequence before using "
        f"/dev/i2c-{iic_index} directly."
    )


def configure_adau1761(
    *,
    sample_rate_hz: int = DEFAULT_SAMPLE_RATE_HZ,
    volume: float = 0.5,
    iic_index: int = DEFAULT_IIC_INDEX,
    allow_direct_i2c_fallback: bool = True,
) -> CodecConfigResult:
    """Configure the PYNQ-Z2 ADAU1761 for PL-driven I2S playback."""

    if not 0.0 <= volume <= 1.0:
        raise ValueError("volume must be in the range 0.0..1.0")

    try:
        _configure_with_pynq_libaudio(iic_index)
        return CodecConfigResult(
            method="pynq_libaudio",
            iic_index=iic_index,
            sample_rate_hz=sample_rate_hz,
            volume=volume,
        )
    except Exception as libaudio_exc:
        if not allow_direct_i2c_fallback:
            raise RuntimeError("Failed to configure ADAU1761 with PYNQ libaudio") from libaudio_exc

        try:
            _configure_with_direct_i2c(iic_index)
            return CodecConfigResult(
                method="direct_i2c",
                iic_index=iic_index,
                sample_rate_hz=sample_rate_hz,
                volume=volume,
            )
        except Exception as direct_exc:
            raise RuntimeError(
                "Failed to configure ADAU1761. Primary PYNQ libaudio path failed, "
                "and direct I2C fallback is unavailable. Confirm that the PYNQ-Z2 "
                "image includes pynq.lib.audio and that the codec I2C bus is /dev/i2c-1."
            ) from direct_exc


def main(argv: Optional[list[str]] = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Configure PYNQ-Z2 ADAU1761 codec for ASK audio demo")
    parser.add_argument("--iic-index", type=int, default=DEFAULT_IIC_INDEX)
    parser.add_argument("--sample-rate-hz", type=int, default=DEFAULT_SAMPLE_RATE_HZ)
    parser.add_argument("--volume", type=float, default=0.5)
    args = parser.parse_args(argv)

    result = configure_adau1761(
        sample_rate_hz=args.sample_rate_hz,
        volume=args.volume,
        iic_index=args.iic_index,
    )
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
