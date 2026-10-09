#!/usr/bin/env python3
"""Publishable metadata/legal repack of the exact, already compiled Build 427.

No compilation, core replacement, or claim of new device testing occurs here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

from delivery_benchmark import payload_fingerprint
from embed_legal_bundle import validate_libretro_notices
from sign_delivery import sign

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL_SHA = '6bfc9ddcb8fbf2be2c21c8c1c68ab2026cf81cb4'
ORIGINAL_IPA_SHA256 = 'acb17ed250b7149d9b38ee91d2eaf70c33d81fc82b006cf78b3ce497a2ea4ab9'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(app):
    result = {}
    for p in app.rglob('*'):
        if p.is_file():
            data = p.read_bytes()
            result[p.relative_to(app).as_posix()] = (
                ('macho', payload_fingerprint(data))
                if data[:4] == b'\xcf\xfa\xed\xfe' else ('file', digest(data)))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if digest(args.ipa.read_bytes()) != ORIGINAL_IPA_SHA256:
        raise SystemExit('Refusing an input other than the exact Build 427 IPA')
    validate_libretro_notices()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    packaging_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        subprocess.run(['ditto', '-xk', str(args.ipa.resolve()), str(stage)], check=True)
        apps = list((stage / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise SystemExit('Expected a single main application')
        app = apps[0]
        before = snapshot(app)
        original_identity = json.loads((app / 'Legal/BUILD_SOURCE_IDENTITY.json').read_text())
        if original_identity['host_commit'] != ORIGINAL_SHA or original_identity['build_number'] != '427':
            raise SystemExit('Build source identity mismatch')
        info_paths = [app / 'Info.plist'] + list(app.glob('PlugIns/*.appex/Info.plist'))
        changed_plists = set()
        for path in info_paths:
            info = plistlib.loads(path.read_bytes())
            if path == app / 'Info.plist' and info['CFBundleVersion'] != '427':
                raise SystemExit('Unexpected build number')
            info['CFBundleShortVersionString'] = '0.0.3'
            path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            changed_plists.add(path.relative_to(app).as_posix())
        # Preserve original source identities and dependency notices; overlay only
        # the reviewed legal documents. No runtime/native resource is removed.
        for source in (ROOT / 'assets/legal').iterdir():
            if source.is_file():
                shutil.copy2(source, app / 'Legal' / source.name)
        shutil.copy2(ROOT / 'NOTICE.md', app / 'Legal/NeoStation-NOTICE.md')
        shutil.copy2(ROOT / 'docs/LEGAL_AND_CREDITS.md', app / 'Legal/LEGAL_AND_CREDITS.md')
        shutil.copy2(ROOT / 'docs/RELEASE_0.0.3_SOURCE_MANIFEST.md', app / 'Legal/RELEASE_0.0.3_SOURCE_MANIFEST.md')
        for dest in [app / 'Legal/Libretro', app / 'Libretro-Licenses']:
            shutil.copytree(ROOT / 'assets/legal/libretro', dest, dirs_exist_ok=True)
        old_notice = app / 'Libretro-Licenses/LIBRETRO_CORES.txt'
        old_notice.write_text(old_notice.read_text().replace(
            'Licence review is pending, as recorded in docs/retroarch-integre-architecture.md.',
            'See LIBRETRO_CORES.md for license texts, restrictions and source-provenance limitations.'))
        psp_license = app / 'LibretroSystem/PPSSPP/LICENSE.TXT'
        if psp_license.is_file():
            shutil.copy2(psp_license, app / 'Legal/Libretro/PPSSPP-bundled-assets-LICENSE.txt')
        release_identity = {
            'release': '0.0.3', 'build': '427', 'original_source_commit': ORIGINAL_SHA,
            'original_ipa_sha256': ORIGINAL_IPA_SHA256, 'packaging_commit': packaging_sha,
            'source_repository': 'https://github.com/TarbleFR/neostation-ios',
            'changes': ['marketing version', 'legal notices', 'ad hoc signatures'],
            'recompiled': False, 'new_device_tests_performed': False,
        }
        (app / 'Release-0.0.3-identity.json').write_text(json.dumps(release_identity, indent=2) + '\n')
        sign(app, output / 'signature.json')
        after = snapshot(app)
        modified = []
        for name in sorted(set(before) | set(after)):
            if before.get(name) == after.get(name):
                continue
            # Mach-O code/data, exports, dependencies and ABI must be identical.
            if before.get(name, ('',))[0] == 'macho' or after.get(name, ('',))[0] == 'macho':
                raise SystemExit('Executable payload changed: ' + name)
            allowed = (name in changed_plists or name.startswith(('Legal/', 'Libretro-Licenses/'))
                       or '/_CodeSignature/' in '/' + name
                       or name == 'Release-0.0.3-identity.json')
            if not allowed:
                raise SystemExit('Unexpected resource change: ' + name)
            modified.append(name)
        core_images = [n for n in before if n.endswith('_libretro') and before[n][0] == 'macho']
        if len(core_images) != 14:
            raise SystemExit('Expected 14 embedded cores')
        ipa = output / 'NeoStation-0.0.3.ipa'
        subprocess.run(['/usr/bin/zip', '-qry', str(ipa), 'Payload'], cwd=stage, check=True)
        subprocess.run(['unzip', '-tq', str(ipa)], check=True)
        with tempfile.TemporaryDirectory() as final_tmp:
            subprocess.run(['ditto', '-xk', str(ipa), final_tmp], check=True)
            final_app = Path(final_tmp) / 'Payload' / app.name
            if snapshot(final_app) != after:
                raise SystemExit('Final ZIP content mismatch')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(final_app)], check=True)
        subprocess.run(['python3', str(ROOT / 'build-utils/validate_legal_bundle_ipa.py'), str(ipa),
                        '--build-number', '427', '--commit', ORIGINAL_SHA], check=True)
        report = dict(release_identity, sha256=digest(ipa.read_bytes()), size_bytes=ipa.stat().st_size,
                      all_compiled_code_and_data_unchanged=True, embedded_cores=len(core_images),
                      changed_resources=modified, zip_integrity='passed', signatures='verified ad hoc')
        (output / 'release-validation.json').write_text(json.dumps(report, indent=2) + '\n')
        legal_zip = output / 'NeoStation-0.0.3-Licenses-and-Notices.zip'
        with zipfile.ZipFile(legal_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
            for base in [app / 'Legal', app / 'Libretro-Licenses', app / 'Dusklight-Licenses']:
                if base.is_dir():
                    for p in base.rglob('*'):
                        if p.is_file(): archive.write(p, p.relative_to(app))
            for p in app.glob('*identity.json'):
                archive.write(p, p.name)
        shutil.copy2(ROOT / 'docs/RELEASE_0.0.3_SOURCE_MANIFEST.md', output / 'NeoStation-0.0.3-Source-Manifest.md')
        for revision, name in [(ORIGINAL_SHA, 'Build427-Source'), (packaging_sha, 'Release-Source'),
                               ('15c72a94c1295ae73dc6c25251469683a16c65e5', 'NeoPlay-0.8.0-Source')]:
            subprocess.run(['git', 'archive', '--format=tar.gz', '--prefix=neostation-ios/',
                            '-o', str(output / f'NeoStation-0.0.3-{name}.tar.gz'), revision], cwd=ROOT, check=True)
    print(json.dumps({k: report[k] for k in ['release', 'build', 'sha256', 'size_bytes', 'embedded_cores',
                                          'all_compiled_code_and_data_unchanged']}))


if __name__ == '__main__':
    main()
