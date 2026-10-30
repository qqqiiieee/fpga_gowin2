"""Validate all banks x 1024 source words before atomically generating the odd half ROM.

On invalid length, endpoints, words or symmetry this program exits nonzero,
prints REFUSED, and never creates or replaces the packed output.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BANKS = 16
POINTS = 1024
HALF = POINTS // 2


def parse_words(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    words = []
    for index, token in enumerate(text.split()):
        token = token.replace("_", "")
        if not re.fullmatch(r"[0-9a-fA-F]{1,4}", token):
            raise ValueError(f"word {index}: expected a defined 16-bit hex word, got {token!r}")
        words.append(int(token, 16))
    return words


def read_words(path):
    return parse_words(Path(path).read_text(encoding="utf-8-sig"))


def pack_odd_words(words, banks=BANKS):
    if not 1 <= banks <= 16:
        raise ValueError("banks must be between 1 and 16")
    if len(words) != banks * POINTS:
        raise ValueError(f"expected {banks * POINTS} source words, got {len(words)}")
    packed = []
    for bank in range(banks):
        wave = words[bank * POINTS:(bank + 1) * POINTS]
        for endpoint in (0, HALF):
            if wave[endpoint] != 0:
                raise ValueError(f"bank {bank} endpoint {endpoint} must be 0000, got {wave[endpoint]:04X}")
        for index in range(POINTS):
            mirror = (-index) % POINTS
            expected = (-wave[index]) & 0xFFFF
            if wave[mirror] != expected:
                raise ValueError(f"bank {bank} index {index}: odd symmetry failed; "
                                 f"w[{mirror}]={wave[mirror]:04X}, -w[{index}]={expected:04X}")
        packed.extend(wave[:HALF])
    # Independent round-trip using the exact hardware address and negate rule.
    for address, original in enumerate(words):
        bank, index = divmod(address, POINTS)
        low = index & (HALF - 1)
        folded = ((-low) & (HALF - 1)) if index & HALF else low
        restored = packed[bank * HALF + folded]
        if index & HALF:
            restored = (-restored) & 0xFFFF
        if restored != original:
            raise ValueError(f"round-trip mismatch at bank {bank}, index {index}")
    return packed


def atomic_write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    name = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", suffix=".tmp", delete=False) as out:
            name = Path(out.name)
            out.write(payload)
        os.replace(name, path)
    finally:
        if name is not None and name.exists():
            name.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "src/timbre_soft.hex")
    parser.add_argument("--output", type=Path, default=ROOT / "src/timbre_odd_half.hex")
    parser.add_argument("--check", action="store_true", help="validate existing output without writing it")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--banks", type=int, default=BANKS,
                        help="number of 1024-point banks; legacy default 16, production dual 2")
    args = parser.parse_args(argv)
    try:
        if args.source.resolve() == args.output.resolve():
            raise ValueError("source and packed output must be different files")
        if args.report is not None and args.report.resolve() in (args.source.resolve(), args.output.resolve()):
            raise ValueError("report must not overwrite source or packed output")
        source_bytes = args.source.read_bytes()
        words = parse_words(source_bytes.decode("utf-8-sig"))
        packed = pack_odd_words(words, args.banks)
        payload = "".join(f"{value:04X}\n" for value in packed).encode("ascii")
        if args.check:
            if read_words(args.output) != packed:
                raise ValueError("existing packed output does not match the validated source; regenerate it")
        else:
            atomic_write(args.output, payload)
        report = {
            "status": "PASS", "source": str(args.source), "output": str(args.output),
            "source_words": len(words), "packed_words": len(packed),
            "banks": args.banks,
            "checked_odd_indices": len(words), "checked_zero_endpoints": args.banks * 2,
            "checked_round_trip_indices": len(words),
            "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
            "canonical_packed_sha256": hashlib.sha256(payload).hexdigest(),
            "check_only": args.check,
        }
        if args.report is not None:
            atomic_write(args.report, (json.dumps(report, indent=2) + "\n").encode("utf-8"))
        print("ODD_HALF_ROM_PASS " + json.dumps(report))
        return 0
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"ODD_HALF_ROM_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
