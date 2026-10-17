#!/usr/bin/env python3
"""Inspect a locally staged AMD test app; never launches it. JSON on stdout."""
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
assert app.name == 'Sill AMD Test.app', 'Expected exact test bundle name'


def run(*args):
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleIdentifier'] == 'local.sill.amd-test'
assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'Sill AMD Test'
assert info['CFBundleExecutable'] == 'Sill'
assert info['LSMinimumSystemVersion'] == '14.0'
assert not list(app.rglob('*.provisionprofile')), 'No provisioning profile allowed'
assert not list(app.rglob('*.mobileprovision')), 'No provisioning profile allowed'
assert sha(app / 'Contents/Resources/LICENSE') == sha(root / 'LICENSE')
assert sha(app / 'Contents/Resources/PORT-CHANGES.md') == sha(root / 'docs/packaging-amd-test.md')

verification = run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
details = run('codesign', '-dvvv', str(app))
requirement = run('codesign', '-d', '-r-', str(app))
assert 'Signature=adhoc' in details
assert 'TeamIdentifier=not set' in details
assert re.search(r'flags=.*\bruntime\b', details)
assert 'designated => cdhash' in requirement
signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                        capture_output=True, check=True)
entitlements = plistlib.loads(signed.stdout)
assert entitlements == {'com.apple.security.get-task-allow': True}, entitlements

machos = []
files = []
for path in sorted(app.rglob('*')):
    assert not path.is_symlink(), f'Unexpected symlink: {path}'
    if not path.is_file():
        continue
    files.append({'path': str(path.relative_to(app)), 'sha256': sha(path), 'size': path.stat().st_size})
    kind = run('file', '-b', str(path)).strip()
    if 'Mach-O' not in kind:
        continue
    archs = run('lipo', '-archs', str(path)).strip()
    assert archs == 'x86_64', (path, archs)
    dependencies = run('otool', '-L', str(path))
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        assert dependency.startswith(('/System/Library/', '/usr/lib/')), dependency
    build = run('xcrun', 'vtool', '-show-build', str(path))
    assert re.search(r'\bminos 14\.0\b', build), build
    machos.append({'path': str(path.relative_to(app)), 'file': kind, 'architectures': archs,
                   'dependencies': dependencies, 'build_version': build})
assert len(machos) == 1 and machos[0]['path'] == 'Contents/MacOS/Sill'

# Retain the exact dirty tracked patch alongside the source commit. Include untracked
# packaging inputs by content hash below; docs/evidence are never executable inputs.
patch = subprocess.run(['git', 'diff', '--binary', 'HEAD'], cwd=root,
                       capture_output=True, check=True).stdout
inputs = ['Scripts/make-app.sh', 'Scripts/verify-amd-test.py', 'docs/packaging-amd-test.md',
          'Packaging/Info.plist', 'Packaging/SillDebug.entitlements', 'LICENSE', 'Package.swift']
manifest = {
    'status': 'STATIC_STAGING_PASS; T14_NOT_RUN',
    'timestamp': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
    'worktree': str(root), 'app': str(app),
    'source_commit': run('git', 'rev-parse', 'HEAD').strip(),
    'upstream_commit': run('git', 'rev-parse', 'baseline/upstream-v0.5.1').strip(),
    'branch': run('git', 'branch', '--show-current').strip(),
    'source_tree': run('git', 'rev-parse', 'HEAD:Sources').strip(),
    'git_status': run('git', 'status', '--porcelain=v1', '--untracked-files=all'),
    'tracked_patch_sha256': hashlib.sha256(patch).hexdigest(),
    'tracked_patch': patch.decode(),
    'inputs': {name: sha(root / name) for name in inputs},
    'commands': ['SILL_SIGN_IDENTITY=- Scripts/make-app.sh --amd-test',
                 'swift build -c release --product SillMenuBar --build-system native --arch x86_64 -j 2',
                 'swift build -c release --product SillMenuBar --build-system native --arch x86_64 -j 2 --show-bin-path',
                 "python3 Scripts/verify-amd-test.py '.build/Sill AMD Test.app'"],
    'tools': {'swift': run('swift', '--version'), 'sdk': run('xcrun', '--show-sdk-version'),
              'developer_directory': run('xcode-select', '-p'), 'os': run('sw_vers'),
              'architecture': run('uname', '-m')},
    'bundle_info': info, 'signature': details, 'verification': verification,
    'designated_requirement': requirement, 'entitlements': entitlements,
    'machos': machos, 'files': files,
    'runtime': 'NOT RUN; no launch/install/Keychain/TCC/device/HEVC/capture test',
    'gatekeeper_notarization': 'NOT RUN; local ad-hoc staging only',
}
print(json.dumps(manifest, indent=2))
