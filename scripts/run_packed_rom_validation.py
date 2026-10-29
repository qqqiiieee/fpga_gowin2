"""Run candidate-local generator guards and frozen-V015 RTL miters; never build Gowin."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
TOPS = ["tb_packed_rom_lookup", "tb_packed_rom_boundaries", "tb_packed_rom_equivalence", "tb_packed_rom_stress", "tb_packed_rom_audio"]
FROZEN_HASHES = {
    "wavetable_synth.v": "c3f7381523a2f30e1083f5d25aab7f4f3e597259e60409d696d3a1486d156301",
    "instrument_audio.v": "f29d0acc5e100e76d5bb2c579e828bfc85c92cd6086be2d90d63bc50fd179562",
}
FIXTURE_HASHES = {
    "wavetable_synth_v015_reference.v": "29f2da0a1228ee56468b7d6d453beb4356554f7f2d38b2537dfe3e32160e2ee4",
    "instrument_audio_v015_reference.v": "571a92efb1d21556232b8ff518fef7cb6526da0e9e46edb5eb1427080f79f525",
}
HELPER_HASHES = {
    "note_table.v": "6597f860e7119b0996317ad3da524787efc4328aa4e887338c7aa2f0aaf21541",
    "oscillator_test_frequencies.v": "7b751337ab88d4b30a97db7d5e5e7b81212eb61d591ca9991e0eac30c23d56e0",
    "voice_allocator.v": "cb948797b44b88ebc87d2316c2d8141900f664d676b5bc104dac1ca36ac5b507",
    "drum_voice.v": "f8d81a9da85d9994ecb77513031a46f91697a60e2cafe1d063a7d750a6040dc2",
    "snare_voice.v": "b4680c709dd84e32218299d1cff151507c20920379c4a37524b95405bcf81ed5",
    "audio_mix.v": "d2db0747ecf1f5488dd9f0a2b66b0bbc8e745d6fdfec4a34969210ed3192c546",
    "dc_blocker.v": "746d834986dcec68e28de5e65d29c9c11f066fd20b406998cb8bbe351534c13f",
    "audio_cleanup.v": "ed7a263a0ae96a060108a58a836c536115b2c4da2b5b9b66042ef20e9f9858b9",
    "audio_controls.v": "00b5054606645d861a07e416e9b81b3430b8f647a5cd12846335d330a7e41040",
    "pt8211_driver.v": "167e6619b3c7cbdb5fbd2b8e8e5c8f8415bac8d552d6717aedbbeb118ef19922",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    project = ROOT if (ROOT / "tools/vendor/iverilog-v12/app/bin/iverilog.exe").exists() else ROOT.parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", type=Path, default=project / "tools/vendor/iverilog-v12/app/bin/iverilog.exe")
    parser.add_argument("--baseline", type=Path, help="optional extra check against the original V015 directory; fixtures are self-contained")
    parser.add_argument("--tests", nargs="+", choices=TOPS, default=TOPS)
    args = parser.parse_args()
    run = ROOT / "validation/packed_rom_sim" / ("run_" + str(time.time_ns()))
    run.mkdir(parents=True)
    report = {"status": "RUNNING", "scope": "RTL/generator only; no synthesis, PnR or hardware",
              "run": str(run), "commands": [], "tests": {}, "source_hashes": {}, "baseline_hashes": {}}

    def save():
        (run / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    def command(argv, label, expected_code=0, timeout=600):
        argv = list(map(str, argv))
        log = run / (label + ".log")
        report["commands"].append({"cwd": str(run), "argv": argv, "log": str(log)})
        with log.open("wb") as output:
            result = subprocess.run(argv, cwd=run, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        text = log.read_text(encoding="utf-8", errors="replace")
        if result.returncode != expected_code:
            raise RuntimeError(f"{label}: exit {result.returncode}, expected {expected_code}\n{text[-4000:]}")
        return text

    print("PACKED_CANDIDATE_RUN " + str(run), flush=True)
    try:
        generator = ROOT / "scripts/generate_odd_half_rom.py"
        command([sys.executable, generator, "--check", "--report", run / "packing_report.json"], "generator_check")
        (run / "src").mkdir()
        for name in ("timbre_soft.hex", "test_sine.hex", "timbre_odd_half.hex"):
            shutil.copyfile(ROOT / "src" / name, run / "src" / name)
        for name, pinned in FROZEN_HASHES.items():
            if args.baseline is not None and sha(args.baseline / "src" / name) != pinned:
                raise RuntimeError("original frozen V015 hash changed: " + name)
            report["baseline_hashes"][name] = pinned
        report["fixture_hashes"] = {}
        for name, pinned in FIXTURE_HASHES.items():
            fixture = ROOT / "tests/fixtures" / name
            if sha(fixture) != pinned:
                raise RuntimeError("frozen reference fixture changed: " + str(fixture))
            report["fixture_hashes"][name] = pinned

        pattern = [0x7FFF, 0x8000, 0xFFFF, 0, 0x8000, 0x7FFF, 1, 0xFFFE]
        def write_hex(path, values):
            path.write_text("".join(f"{v:04X}\n" for v in values), encoding="ascii")
        write_hex(run / "stress_wave.hex", [pattern[(i + i // 1024) % 8] for i in range(16384)])
        write_hex(run / "stress_sine.hex", [pattern[(i * 3 + 1) % 8] for i in range(1024)])
        odd = []
        for bank in range(16):
            values = [0] * 1024
            for i in range(1, 512):
                values[i] = pattern[(i + bank) % 8]
                values[1024 - i] = (-values[i]) & 0xFFFF
            odd.extend(values)
        write_hex(run / "full_range_odd.hex", odd)
        command([sys.executable, generator, "--source", run / "full_range_odd.hex", "--output",
                 run / "full_range_odd_half.hex", "--report", run / "full_range_packing_report.json"], "generator_full_range")

        source = [int(x, 16) for x in (ROOT / "src/timbre_soft.hex").read_text().split()]
        guard_cases = []
        for bank in range(16):
            for endpoint in (0, 512):
                bad = source.copy();bad[bank * 1024 + endpoint] = 0x8000
                guard_cases.append((f"endpoint_{bank}_{endpoint}", bad))
            bad = source.copy();bad[bank * 1024 + 700] ^= 1
            guard_cases.append((f"odd_{bank}_700", bad))
        guard_cases.append(("length", source[:-1]))
        sentinel = b"preserve existing output\n"
        bad_source = run / "guard_source.hex"
        guarded_output = run / "guard_output.hex"
        guarded_report = run / "guard_report.json"
        for label, words in guard_cases:
            write_hex(bad_source, words)
            guarded_output.write_bytes(sentinel);guarded_report.write_bytes(sentinel)
            text = command([sys.executable, generator, "--source", bad_source, "--output", guarded_output,
                            "--report", guarded_report], "refused_" + label, expected_code=1)
            if "ODD_HALF_ROM_REFUSED" not in text or guarded_output.read_bytes() != sentinel or guarded_report.read_bytes() != sentinel:
                raise RuntimeError("generator rejection modified existing output: " + label)
        for label, token in (("unknown", "XXXX"), ("too_wide", "10000")):
            bad_source.write_text(token + "\n", encoding="ascii")
            text = command([sys.executable, generator, "--source", bad_source, "--output", guarded_output],
                           "refused_" + label, expected_code=1)
            if "ODD_HALF_ROM_REFUSED" not in text or guarded_output.read_bytes() != sentinel:
                raise RuntimeError("generator word guard failed: " + label)
        # An invalid source must not even create the output directory.
        absent = run / "must_not_be_created/output.hex"
        command([sys.executable, generator, "--source", bad_source, "--output", absent], "refused_absent_output", expected_code=1)
        if absent.parent.exists():
            raise RuntimeError("invalid generation created an output directory")
        stale = run / "stale_half.hex"
        stale.write_bytes((ROOT / "src/timbre_odd_half.hex").read_bytes())
        content = stale.read_text();stale.write_text("FFFF" + content[4:], encoding="ascii")
        previous = stale.read_bytes()
        text = command([sys.executable, generator, "--output", stale, "--check"], "refused_stale", expected_code=1)
        if "ODD_HALF_ROM_REFUSED" not in text or stale.read_bytes() != previous:
            raise RuntimeError("stale --check did not reject without writing")
        report["generator_guards"] = {"status": "PASS", "rejected_cases": len(guard_cases) + 4,
                                      "existing_outputs_preserved": True, "absent_output_stays_absent": True}
        print("GENERATOR_GUARDS_PASS cases=" + str(len(guard_cases) + 4), flush=True)

        sources = [ROOT / "src" / name for name in sorted([*FROZEN_HASHES, *HELPER_HASHES])]
        # Both references share only unchanged helper modules with the candidate.
        for source_file in sources:
            if source_file.name in HELPER_HASHES and sha(source_file) != HELPER_HASHES[source_file.name]:
                raise RuntimeError("helper differs from frozen V015: " + str(source_file))
        sources += [ROOT / "tests/fixtures" / name for name in FIXTURE_HASHES]
        sources += [ROOT / "tests/tb_packed_rom_equivalence.v", ROOT / "tests/tb_packed_rom_boundaries.v"]
        report["source_hashes"] = {str(p.relative_to(ROOT)).replace("\\", "/"): sha(p)
                                   for p in (ROOT / "src").glob("*") if p.is_file()}
        report["source_hashes"]["tests/tb_packed_rom_equivalence.v"] = sha(ROOT / "tests/tb_packed_rom_equivalence.v")
        report["source_hashes"]["tests/tb_packed_rom_boundaries.v"] = sha(ROOT / "tests/tb_packed_rom_boundaries.v")
        save()
        for top in args.tests:
            print("START " + top, flush=True)
            output = run / (top + ".vvp")
            command([args.iverilog, "-g2012", "-Wall", "-s", top, "-o", output, *sources], top + "_compile")
            text = command([args.iverilog.with_name("vvp.exe"), output], top + "_simulation")
            marker = top.upper().replace("TB_", "") + "_TEST_PASS"
            if marker not in text or re.search(r"FATAL:|ERROR:|TEST_FAIL", text):
                raise RuntimeError(top + " did not pass\n" + text[-5000:])
            report["tests"][top] = {"status": "PASS", "log": str(run / (top + "_simulation.log"))}
            print(text[-1800:], flush=True)
            save()
        report["status"] = "PASS"
        save()
        print("PACKED_ROM_CANDIDATE_ALL_PASS " + str(run), flush=True)
        return 0
    except Exception as exc:
        report["status"] = "FAIL";report["error"] = str(exc);save()
        print("PACKED_ROM_CANDIDATE_FAIL " + str(exc), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
