"""生成 9-bit 字符单元常量。缺字、长度超出和旧编码不一致都会拒绝写入。"""
from pathlib import Path
import argparse, json

ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--check',action='store_true');args=ap.parse_args()
    mapping=json.loads((ROOT/'assets/ui_font_map.json').read_text(encoding='utf-8'))['hanzi']
    data=json.loads((ROOT/'assets/ui_texts.json').read_text(encoding='utf-8'))
    lines=['// 自动生成：python scripts/generate_ui_text.py；编辑 assets/ui_texts.json。',
           '// 位 287..279 是第 0 个字符单元；汉字占左右两个单元，空格补齐 32 个。']
    names=set()
    for item in data['texts']:
        assert item['name'] not in names;names.add(item['name']);cells=[]
        for c in item['text']:cells.extend([ord(c)] if ord(c)<128 else mapping[c])
        assert len(cells)<=data['cells'],item
        cells.extend([32]*(data['cells']-len(cells)));value=0
        for c in cells:value=(value<<9)|c
        hex_value=f'{value:072x}'
        if 'hex' in item:assert hex_value==item['hex'],f"旧编码不一致 {item['name']}"
        lines.append(f"localparam [287:0] {item['name']} = 288'h{hex_value}; // {item['text']}")
    output='\n'.join(lines)+'\n';dest=ROOT/'src/hdmi_ui_text.vh'
    if args.check:assert dest.read_text(encoding='utf-8')==output,'生成头文件已过期'
    else:dest.write_text(output,encoding='utf-8')
    print('UI_TEXT_CHECK_PASS' if args.check else 'UI_TEXT_GENERATED',len(names))
if __name__=='__main__':main()
