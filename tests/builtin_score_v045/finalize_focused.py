"""Freeze the requested focused evidence without running or changing RTL.

Keep the complete reports (including timeouts/stopped repeats) immutable.
Latest report clearly distinguishes 25 current directed passes from two earlier
full-period passes whose relevant source differs only in standalone comments.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    recent_path = HERE / "results/20261031T102913_962136Z/report.json"
    earlier_path = HERE / "results/20261031T102054_122084Z/report.json"
    recent = json.loads(recent_path.read_text(encoding="utf-8"))
    earlier = json.loads(earlier_path.read_text(encoding="utf-8"))
    # No live changes since the latest frozen simulation inputs (runner included).
    assert all(digest(ROOT / name) == value for name, value in recent["snapshot_sha256"].items())
    long_names = {"builtin_guide_46875", "legacy_guide_46875"}
    focused = [case for case in recent["tests"] if case["name"] not in long_names]
    assert len(focused) == 25 and all(case["passed"] for case in focused)
    for case in focused:
        case["evidence_report"] = str(recent_path)
        for part in ("compile", "simulation"):
            case[part]["absolute_log"] = str(Path(recent["result_directory"]) / case[part]["log"])
    prior = []
    old_snapshot = Path(earlier["result_directory"]) / "snapshot"
    current_snapshot = Path(recent["result_directory"]) / "snapshot"
    for name in sorted(long_names):
        case = next(c for c in earlier["tests"] if c["name"] == name)
        stopped = next(c for c in recent["tests"] if c["name"] == name)
        assert case["passed"]
        files = [arg for arg in case["compile"]["argv"] if arg.endswith(".v")]
        files += ["src/piano_song_rom_v045.vh", "src/piano_builtin_score.hex",
                  "tests/song_library_v045/source.json", "tests/builtin_score_v045/oracle.hex"]
        comment_only = []
        for relative in files:
            before, after = (old_snapshot / relative).read_bytes(), (current_snapshot / relative).read_bytes()
            if before != after:
                assert relative == "src/piano_roll_guide.v"
                def without_comment_lines(data):
                    return [line for line in data.decode("utf-8").splitlines()
                            if not line.lstrip().startswith("//")]
                assert without_comment_lines(before) == without_comment_lines(after)
                comment_only.append(relative)
        assert [a for a in case["compile"]["argv"] if a.startswith("-P")] == [
            a for a in stopped["compile"]["argv"] if a.startswith("-P")]
        prior.append(dict(name=name, passed=True, evidence_report=str(earlier_path),
            simulation=case["simulation"], compared_inputs=files,
            comment_only_differences=comment_only, executable_inputs_equivalent=True,
            latest_repeat="Stopped at user request to finish focused validation; not a functional assertion failure",
            stopped_repeat_report=str(recent_path)))
    resource = json.loads((HERE / "resource_report.json").read_text(encoding="utf-8"))
    assert resource["passed"] and all(digest(ROOT / n) == h for n, h in resource["source_sha256"].items())
    report = dict(passed=True, scope="25 current focused cases; 2 earlier complete-period passes with executable input equivalence",
        source_frozen=True, frozen_at_utc=datetime.now(timezone.utc).isoformat(),
        focused_case_count=25, tests=focused, prior_complete_period_checks=prior,
        prior_complete_period_count=2, latest_long_repeats_stopped=True,
        source_sha256=resource["source_sha256"], resource_report=str(HERE / "resource_report.json"),
        experimental_resource_mapping_passed=True, production_build=False, programming=False, publication=False,
        raw_latest_attempt_report=str(recent_path), unresolved_rtl_failures=[])
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    (HERE / "freeze_report.json").write_text(text, encoding="utf-8")
    (HERE / "latest_report.json").write_text(text, encoding="utf-8")
    print("BUILTIN_V045_FROZEN_PASS focused=25 prior_complete_period=2 source_equivalence=1 unresolved_rtl_failures=0")


if __name__ == "__main__":
    main()
