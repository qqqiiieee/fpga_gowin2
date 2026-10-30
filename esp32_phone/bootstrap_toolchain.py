"""Isolated, pinned Windows build subset. Downloads only Arduino/Espressif assets.
No board discovery, serial access, upload, global config, or third-party libraries.
The filesystem tools/debuggers for other chips are deliberately not installed.
"""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import shutil
import time
import urllib.request
import urllib.parse
import zipfile
import tarfile

ROOT = Path(__file__).resolve().parent
TC = ROOT / '.toolchain'
DATA = TC / 'data'
VERSION = '2.0.17'

def download(url, path, checksum=None):
    host = urllib.parse.urlparse(url).hostname
    if host not in ('downloads.arduino.cc', 'espressif.github.io') and not url.startswith(('https://github.com/espressif/', 'https://github.com/arduino/')):
        raise ValueError('Non Arduino/Espressif URL rejected: ' + url)
    path.parent.mkdir(parents=True, exist_ok=True)
    def valid():
        return path.exists() and (not checksum or hashlib.sha256(path.read_bytes()).hexdigest().lower() == checksum.split(':')[-1].lower())
    if valid():
        return
    part = path.with_suffix(path.suffix + '.part')
    for attempt in range(3):
        try:
            print('Download:', url, flush=True)
            req = urllib.request.Request(url, headers={'User-Agent': 'Tang20K-offline-build/1.0'})
            with urllib.request.urlopen(req, timeout=45) as response, part.open('wb') as out:
                shutil.copyfileobj(response, out, 1024 * 1024)
            part.replace(path)
            if not valid():
                path.unlink()
                raise ValueError('SHA256 mismatch: ' + url)
            return
        except Exception as error:
            print('Attempt', attempt + 1, str(error), flush=True)
            if attempt == 2:
                raise
            time.sleep(2)

def extract(archive, target, strip=True):
    if (target / '.bridge-installed').exists():
        return
    target.mkdir(parents=True, exist_ok=True)
    stage = TC / 'extract' / target.name
    stage.mkdir(parents=True, exist_ok=True)
    # All assets are checksummed official archives. Still reject path traversal.
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                if not (stage / name).resolve().is_relative_to(stage.resolve()):
                    raise ValueError('Archive path traversal')
            z.extractall(stage)
    else:
        with tarfile.open(archive) as t:
            for member in t.getmembers():
                if not (stage / member.name).resolve().is_relative_to(stage.resolve()) or member.issym() or member.islnk():
                    raise ValueError('Unsafe archive member')
            t.extractall(stage, filter='data')
    entries = list(stage.iterdir())
    source = entries[0] if strip and len(entries) == 1 and entries[0].is_dir() else stage
    shutil.copytree(source, target, dirs_exist_ok=True)
    (target / '.bridge-installed').write_text(str(archive.name), encoding='utf-8')

def main():
    TC.mkdir(exist_ok=True)
    DATA.mkdir(exist_ok=True)
    cli_url = 'https://downloads.arduino.cc/arduino-cli/arduino-cli_1.2.2_Windows_64bit.zip'
    download(cli_url, TC / 'arduino-cli.zip')
    # Arduino publishes the CLI archive checksum separately.
    sums = TC / 'arduino-cli_checksums.txt'
    download('https://github.com/arduino/arduino-cli/releases/download/v1.2.2/1.2.2-checksums.txt', sums)
    cli_hash = next(line.split()[0] for line in sums.read_text().splitlines() if 'arduino-cli_1.2.2_Windows_64bit.zip' in line)
    if hashlib.sha256((TC / 'arduino-cli.zip').read_bytes()).hexdigest() != cli_hash:
        raise ValueError('CLI checksum mismatch')
    extract(TC / 'arduino-cli.zip', TC / 'cli', strip=False)
    download('https://espressif.github.io/arduino-esp32/package_esp32_index.json', TC / 'package_esp32_index.json')
    download('https://downloads.arduino.cc/packages/package_index.json', TC / 'package_index.json')
    esp_index = json.loads((TC / 'package_esp32_index.json').read_text())
    index = json.loads((TC / 'package_index.json').read_text())
    esp = next(p for p in esp_index['packages'] if p['name'] == 'esp32')
    core = next(c for c in esp['platforms'] if c['version'] == VERSION)
    artifacts = [(core, DATA / 'packages' / 'esp32' / 'hardware' / 'esp32' / VERSION)]
    # The WROOM32 compiler and elf2image tool are the only Espressif tools used by
    # compile. No mkspiffs/mklittlefs, debuggers, upload/discovery or other chips.
    for dep in core['toolsDependencies']:
        if dep['name'] not in ('xtensa-esp32-elf-gcc', 'esptool_py'):
            continue
        tool = next(t for t in esp['tools'] if t['name'] == dep['name'] and t['version'] == dep['version'])
        system = next(s for s in tool['systems'] if s['host'] in ('x86_64-mingw32', 'i686-mingw32'))
        artifacts.append((system, DATA / 'packages' / 'esp32' / 'tools' / dep['name'] / dep['version']))
    builtin = next(p for p in index['packages'] if p['name'] == 'builtin')
    ctags = next(t for t in builtin['tools'] if t['name'] == 'ctags')
    system = next(s for s in ctags['systems'] if s['host'] in ('x86_64-mingw32', 'i686-mingw32', 'i686-mingw32msvc'))
    artifacts.append((system, DATA / 'packages' / 'builtin' / 'tools' / 'ctags' / ctags['version']))
    def install(pair):
        entry, target = pair
        archive = TC / 'downloads' / entry['archiveFileName']
        download(entry['url'], archive, entry['checksum'])
        extract(archive, target)
        print('Installed:', target.relative_to(TC), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(install, artifacts))
    for name in ('package_index.json', 'package_esp32_index.json'):
        shutil.copy2(TC / name, DATA / name)
    (DATA / 'library_index.json').write_text('{"libraries":[]}', encoding='utf-8')
    config = {'directories': {'data': str(DATA), 'downloads': str(TC / 'downloads'), 'user': str(TC / 'sketchbook')},
              'board_manager': {'additional_urls': ['https://espressif.github.io/arduino-esp32/package_esp32_index.json']},
              'metrics': {'enabled': False}}
    (TC / 'arduino-cli.yaml').write_text(json.dumps(config, indent=2), encoding='utf-8')
    manifest = {'cli': '1.2.2', 'core': VERSION, 'fqbn': 'esp32:esp32:esp32', 'cli_sha256': cli_hash,
                'artifacts': [{'url': e['url'], 'checksum': e['checksum']} for e, _ in artifacts]}
    (TC / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print('Ready. Run .\\build.ps1 (compile only).', flush=True)

if __name__ == '__main__':
    main()
