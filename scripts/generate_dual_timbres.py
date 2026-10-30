"""从冻结的16音色基准挑选长笛/拨弦，逐字验证后生成实际使用的两音色ROM。

完整基准只作资产来源，生产只实例化两音色半表。--check同时拒绝选错bank、
源表哈希变化、半表失配；不得通过截断原文件前两组来替代选取旧ID1/7。
"""
from pathlib import Path
import argparse
import hashlib
import json
from generate_odd_half_rom import atomic_write, read_words, pack_odd_words

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'assets/timbres_dual.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    data = json.loads(MANIFEST.read_text(encoding='utf-8'))
    source = ROOT / data['source']
    if hashlib.sha256(source.read_bytes()).hexdigest() != data['source_sha256']:
        raise ValueError('frozen source hash changed')
    waves = read_words(source)
    if len(waves) != 16 * 1024:
        raise ValueError('frozen source must contain 16 x 1024 words')
    if [item['id'] for item in data['timbres']] != [0, 1]:
        raise ValueError('production IDs must be 0, 1')
    if [item['source_bank'] for item in data['timbres']] != [1, 7]:
        raise ValueError('production source banks must be 1, 7')
    selected = []
    for item in data['timbres']:
        offset = item['source_bank'] * 1024
        selected.extend(waves[offset:offset + 1024])
    packed = pack_odd_words(selected, banks=2)
    for path, words in [(ROOT/'src/timbre_dual.hex', selected),
                        (ROOT/'src/timbre_dual_half.hex', packed)]:
        if args.check:
            if read_words(path) != words:
                raise ValueError(f'stale or invalid generated asset: {path}')
        else:
            atomic_write(path, ''.join(f'{value:04X}\n' for value in words).encode('ascii'))
    print('DUAL_TIMBRE_CHECK_PASS' if args.check else 'DUAL_TIMBRE_GENERATED',
          'banks=2 original_words=2048 stored_words=1024 source_banks=1,7')


if __name__ == '__main__':
    main()
