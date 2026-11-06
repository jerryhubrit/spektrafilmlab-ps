#!/usr/bin/env python3
"""Assemble public artifacts from an explicit allowlist; never ship local config."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = json.loads((ROOT / 'plugin/manifest.json').read_text())['version']
NAME = f'SpektraFilmLab-PS-v{VERSION}-macOS-arm64'
DIST = ROOT / 'dist'
KIT = DIST / NAME

def source_files():
    for name in ['LICENSE', 'NOTICE.md', 'README.md', 'upstream.json', '.gitignore',
                 'plugin', 'helper', 'installer', 'scripts', 'tests', 'licenses', 'assets', 'docs', 'vendor']:
        path = ROOT / name
        for item in sorted(path.rglob('*')) if path.is_dir() else [path]:
            rel = item.relative_to(ROOT)
            if not item.is_file() or any(x in rel.parts for x in ('build', '__pycache__', '.DS_Store')):
                continue
            if rel == Path('plugin/config.json') or item.suffix in ('.ccx', '.pyc'):
                continue
            yield item

def main():
    DIST.mkdir(exist_ok=True)
    if KIT.exists():
        shutil.rmtree(KIT)
    KIT.mkdir()
    shutil.copytree(ROOT / 'build/bin', KIT / 'bin')
    shutil.copytree(ROOT / 'vendor/SpektraLab/engine/resources', KIT / 'resources')
    shutil.copytree(ROOT / 'plugin', KIT / 'plugin', ignore=shutil.ignore_patterns('config.json', '.DS_Store'))
    shutil.copytree(ROOT / 'licenses', KIT / 'licenses')
    for dependency, license_name in [('metal-cpp', 'LICENSE.txt'), ('stb', 'LICENSE'), ('volk', 'LICENSE.md')]:
        target = KIT / 'licenses/third_party' / dependency
        target.mkdir(parents=True)
        shutil.copy2(ROOT / 'vendor/SpektraLab/engine/third_party' / dependency / license_name, target / license_name)
    for name in ['LICENSE', 'NOTICE.md', 'upstream.json']:
        shutil.copy2(ROOT / name, KIT / name)
    shutil.copy2(ROOT / 'docs/INSTALL.md', KIT / '安装与使用.md')
    for label, action in [('安装', 'install "$filmlab_package"'), ('启动引擎', 'start'), ('停止引擎', 'stop')]:
        script = KIT / f'{label}.command'
        script.write_text('#!/bin/bash\n'
            'filmlab_package=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
            f'"$filmlab_package/bin/FilmLabSetup" {action}\n'
            'filmlab_status=$?\n'
            'if [[ $filmlab_status -ne 0 ]]; then printf "\\n操作未完成，请查看上方提示和安装与使用.md。\\n"; fi\n'
            'printf "\\n按回车关闭此窗口…"\nread -r\nexit "$filmlab_status"\n')
        script.chmod(0o755)
    archive = DIST / f'{NAME}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for item in sorted(KIT.rglob('*')):
            if item.is_file():
                z.write(item, item.relative_to(DIST))
    source = DIST / f'SpektraFilmLab-PS-v{VERSION}-source.tar.gz'
    with tarfile.open(source, 'w:gz') as t:
        for item in source_files():
            info = t.gettarinfo(str(item), arcname=f'spektrafilmlab-ps-{VERSION}/{item.relative_to(ROOT)}')
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            with item.open('rb') as f:
                t.addfile(info, f)
    checksums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in [archive, source])
    (DIST / 'SHA256SUMS.txt').write_text(checksums)
    print(checksums, end='')
    print(f'Kit: {len(list(KIT.rglob("*")))} entries; source: {len(list(source_files()))} files')

if __name__ == '__main__':
    main()
