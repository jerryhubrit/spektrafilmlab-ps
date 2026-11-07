"""Validate the actual release kit in isolated temporary destinations on port 49322."""
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
version = json.loads((ROOT / 'plugin/manifest.json').read_text())['version']
kit = ROOT / 'dist' / f'SpektraFilmLab-PS-v{version}-macOS-arm64'
setup = kit / 'bin/FilmLabSetup'

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

with zipfile.ZipFile(Path(str(kit) + '.zip')) as z:
    names = z.namelist()
    assert not any(Path(n).name == 'config.json' or n.endswith('.ccx') for n in names)
    assert not any(Path(n).suffix.lower() in ('.arw', '.cr2', '.cr3', '.nef', '.dng', '.psd') for n in names)
    for info in z.infolist():
        if info.filename.endswith('.command') or '/bin/' in info.filename:
            assert (info.external_attr >> 16) & 0o111, info.filename
for line in (ROOT / 'dist/SHA256SUMS.txt').read_text().splitlines():
    digest, name = line.split('  ', 1)
    assert hashlib.sha256((ROOT / 'dist' / name).read_bytes()).hexdigest() == digest
for binary in (kit / 'bin').iterdir():
    run('/usr/bin/codesign', '--verify', '--strict', binary)
    output = subprocess.check_output(['vtool', '-show-build', str(binary)], text=True)
    assert 'minos 15.0' in output, output
    assert 'arm64' in subprocess.check_output(['file', str(binary)], text=True)
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    assert all(x.strip().startswith(('/System/', '/usr/lib/', '@rpath/')) for x in dependencies), dependencies
    assert b'/Users/' not in binary.read_bytes(), 'Local build path embedded'

# Refuse to replace the source cache of a helper that is already in use.
with socket.socket() as probe:
    assert probe.connect_ex(('127.0.0.1', 49322)) != 0, 'Test port 49322 already in use'
with tempfile.TemporaryDirectory(prefix='spektrafilmlab-release-') as temp:
    first, second = Path(temp) / 'first', Path(temp) / 'second'
    for destination in (first, second):
        run(setup, 'prepare', kit, destination, 49322)
    a, b = [json.loads((p / 'config.json').read_text()) for p in (first, second)]
    assert len(a['token']) >= 32 and a['token'] != b['token']
    assert stat.S_IMODE(first.stat().st_mode) == 0o700
    for relative in ('config.json', 'plugin/config.json', 'SpektraFilmLab-PS.ccx'):
        assert stat.S_IMODE((first / relative).stat().st_mode) == 0o600
    with zipfile.ZipFile(first / 'SpektraFilmLab-PS.ccx') as ccx:
        assert json.loads(ccx.read('config.json')) == a
        assert json.loads(ccx.read('manifest.json'))['version'] == version
    run(setup, 'prepare', kit, first, 49322)
    assert json.loads((first / 'config.json').read_text()) == a
    try:
        run(setup, 'start-at', first)
        request = urllib.request.Request('http://127.0.0.1:49322/health', headers={'Authorization': 'Bearer ' + a['token']})
        with urllib.request.urlopen(request) as response:
            assert json.load(response)['version'] == version
        env = dict(os.environ, FILMLAB_CONFIG=str(first / 'config.json'))
        for name in ('native_smoke.py', 'edge_smoke.py'):
            run('python3', ROOT / 'tests' / name, env=env)
        for index, path in enumerate(sys.argv[1:], 1):
            run('python3', ROOT / 'tests/raw_smoke.py', Path(path).resolve(), '--full', env=env)
            (ROOT / 'build' / f'raw-smoke-{index}.json').write_bytes((ROOT / 'build/raw-smoke.json').read_bytes())
    finally:
        run(setup, 'stop-at', first)
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1', 49322)) != 0, 'Test helper did not stop'
print('PASS: artifact hashes, executable modes, signatures, deployment targets, dependencies, private configuration, CCX layout, independent tokens, token reuse, helper lifecycle and real Metal renders')
