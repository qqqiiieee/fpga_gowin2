"""生成按列共享的中文文本译码，不再在像素路径传递288位整行文本。

原始 assets/ui_texts.json 和 hdmi_ui_text.vh 保留为独立回归参考。
这里先把每行映射为8位文本编号，再按列合并输出同一字符的编号。
仅改变组合逻辑的表达方式：字符编码、坐标、字模ROM和像素延迟均不变。
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def render() -> str:
    data = json.loads((ROOT / 'assets/ui_texts.json').read_text(encoding='utf-8'))
    mapping = json.loads((ROOT / 'assets/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']
    texts = data['texts']
    assert data['cells'] == 32 and len(texts) < 255
    rows = []
    lines = [
        '// 自动生成：python scripts/generate_ui_lookup.py；请修改assets/ui_texts.json。',
        '// 列优先共享译码：8位文本ID + 5位列号 -> 9位半字符编码。',
        '// 不增加寄存器或BRAM；字模读取及RGB流水延迟保持不变。',
        'localparam [7:0] TXID_BLANK = 8\'d255;',
    ]
    for index, item in enumerate(texts):
        cells = []
        for char in item['text']:
            cells.extend([ord(char)] if ord(char) < 128 else mapping[char])
        assert len(cells) <= 32
        cells += [32] * (32 - len(cells))
        value = 0
        for cell in cells:
            value = (value << 9) | cell
        if 'hex' in item:
            assert f'{value:072x}' == item['hex'], item['name']
        rows.append(cells)
        name = item['name'].replace('TXT_', 'TXID_', 1)
        lines.append(f"localparam [7:0] {name} = 8'd{index}; // {item['text']}")
    lines += ['function [8:0] ui_text_cell;', '    input [7:0] text_id;',
              '    input [4:0] column;', '    begin', "        ui_text_cell = 9'd32;",
              '        case (column)']
    for column in range(32):
        groups = collections.defaultdict(list)
        for index, row in enumerate(rows):
            if row[column] != 32:
                groups[row[column]].append(index)
        if not groups:
            continue
        lines += [f"            5'd{column}: case (text_id)"]
        for glyph, indices in sorted(groups.items()):
            ids = ','.join(f"8'd{index}" for index in indices)
            lines += [f"                {ids}: ui_text_cell = 9'd{glyph};"]
        lines += ["                default: ui_text_cell = 9'd32;", '            endcase']
    lines += ["            default: ui_text_cell = 9'd32;", '        endcase', '    end', 'endfunction', '']
    return '\n'.join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = render()
    path = ROOT / 'src/hdmi_ui_lookup.vh'
    if args.check:
        assert path.read_text(encoding='utf-8') == output, '文本查找头文件已过期'
    else:
        path.write_text(output, encoding='utf-8')
    print('UI_LOOKUP_CHECK_PASS' if args.check else 'UI_LOOKUP_GENERATED')


if __name__ == '__main__':
    main()
