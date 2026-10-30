"""生成/核验触摸中心；默认JSON是估算，不能替代逐键实测校准。"""
from __future__ import annotations

import argparse
from fractions import Fraction
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROW_MAJOR = ["1", "2", "3", "A", "4", "5", "6", "B",
             "7", "8", "9", "C", "*", "0", "#", "D"]
REFERENCE = dict(zip(
    ["1", "4", "7", "*", "2", "5", "8", "0", "3", "6", "9", "#", "A", "B", "C", "D"],
    [30, 82, 134, 199, 246, 295, 368, 418, 482, 541, 610, 649, 692, 752, 800, 868]))
DATASHEET = "https://ww1.microchip.com/downloads/aemDocuments/documents/APID/ProductDocuments/DataSheets/21298e.pdf"


def reference_defaults():
    # 有理数换算后四舍五入，避开浮点及银行家舍入的语义差异。
    scale = Fraction(4095 * 33, 1023 * 2 * 25)
    centers = []
    for key in ROW_MAJOR:
        value = REFERENCE[key] * scale
        centers.append((2 * value.numerator + value.denominator) // (2 * value.denominator))
    return {
        "schema_version": 1,
        "status": "estimated_not_measured",
        "hardware_measured": False,
        "runtime_calibration_required": True,
        "row_major_keys": ROW_MAJOR,
        "centers": centers,
        "reference_10bit": REFERENCE,
        "reference_correction": "商家752对应B；商家表中误印为C。",
        "estimate_formula": "round(ref*4095*3.3/(1023*2*2.5))",
        "assumptions": {"module_supply_v": 3.3, "external_divider": [10000, 10000],
                        "adc_vref_v": 2.5, "module_internal_divider": "unknown"},
        "recognition": {"idle_raw_below": 4, "center_min": 8, "center_max": 4094,
                        "minimum_center_separation": 12, "ambiguity_distance_margin": 2,
                        "window": "max(2,min(32,nearest_gap>>2))", "idle_center": 0,
                        "stable_samples": 3},
        "persistence": "运行时仅修改FPGA RAM；复位恢复hex。主机将实测中心按rowmajor写入centers，运行本脚本后重新编译实现持久化。",
        "limits": ["原始参考只用于启动，未知内部分压可能压缩中心，必须运行时逐键校准。",
                   "中心小于8或间距小于12说明前端量程不可用，不强行合并键位。",
                   "固定模拟假值若恰在有效档位，无法与真实长按区分；只保证无效或过期时释放。"],
        "datasheet": {"url": DATASHEET, "document": "DS21298E", "sections": ["5", "6.1", "Figure 6-1"]},
    }


def validate(data):
    if data.get("row_major_keys") != ROW_MAJOR:
        raise ValueError("row_major_keys必须严格匹配16键行序，不能按模拟电压排序")
    centers = data.get("centers")
    if not isinstance(centers, list) or len(centers) != 16:
        raise ValueError("centers必须包含16个按rowmajor排列的整数")
    if any(type(value) is not int or not 8 <= value <= 4094 for value in centers):
        raise ValueError("前端量程不可用：中心必须是8..4094内的整数")
    for i, value in enumerate(centers):
        for j in range(i):
            if abs(value - centers[j]) < 12:
                raise ValueError(f"前端量程不可用：{ROW_MAJOR[j]}/{ROW_MAJOR[i]}中心间距小于12")
    return centers


def render_hex(data):
    return "".join(f"{value:03x}\n" for value in validate(data))


def render_init(data):
    packed=''.join(f'{v:03x}' for v in reversed(validate(data)))
    return '// Generated from touch calibration JSON; word0 occupies bits[11:0].\n'+f"localparam [191:0] TOUCH_DEFAULT_CENTERS = 192'h{packed};\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", "--calibration", dest="calibration", type=Path,
                        default=ROOT / "assets/touch_calibration.json")
    parser.add_argument("--output", type=Path, default=ROOT / "src/touch_centers.hex")
    parser.add_argument("--from-reference", action="store_true", help="重建未实测的商家参考默认JSON及hex")
    parser.add_argument("--check", action="store_true", help="仅核验JSON与现有hex，不写文件")
    args = parser.parse_args()
    if args.from_reference and args.check:
        parser.error("--from-reference和--check不能同时使用")
    try:
        data = reference_defaults() if args.from_reference else json.loads(args.calibration.read_text(encoding="utf-8-sig"))
        expected = render_hex(data)
        init_path=args.output.with_name(args.output.stem+'_init.vh')
        expected_init=render_init(data)
        if args.check:
            if args.output.read_text(encoding="utf-8") != expected:
                raise ValueError("hex与校准JSON不一致，请重新生成")
            if init_path.read_text(encoding='ascii') != expected_init:
                raise ValueError('复位常量与校准JSON不一致，请重新生成hex和init.vh')
        else:
            if args.from_reference:
                args.calibration.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            args.output.write_text(expected, encoding="ascii")
            init_path.write_text(expected_init,encoding='ascii')
        print(json.dumps({"status": "pass", "check_only": args.check,
                          "centers": data["centers"], "hex": str(args.output)}, ensure_ascii=False))
    except (OSError, ValueError, TypeError) as exc:
        parser.exit(1, f"touch calibration error: {exc}\n")


if __name__ == "__main__":
    main()
