#!/usr/bin/env python3
"""Build support confined to Dolphin's test workflow and generated iOS host."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from verify_ipa import BRIDGE, demand, file_sha256, macho, validate

ROOT = Path(__file__).resolve().parents[3]
LOGS = ROOT / 'build/dolphin-ci'
STIK_SHA = '444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85'


def run(*args: str, cwd: Path = ROOT) -> None:
    subprocess.run(list(args), cwd=cwd, check=True)


def plist(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())


def write_plist(path: Path, data: dict) -> None:
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))


def source_snapshot() -> None:
    paths = ['.github/workflows/dolphin-internal-isolated-v3.yml', 'build-utils',
             'native/dolphin_internal_helper', 'packages/dolphin_internal_bridge',
             'packages/dolphin_jit_helper', 'packages/stikjit_bridge',
             'lib/services/dolphin_internal_v2_service.dart',
             'lib/widgets/dolphin_internal_playlist_actions.dart',
             'lib/services/game/game_launch_service.dart',
             'lib/providers/sqlite_config_provider.dart',
             'lib/providers/sqlite_config_provider/scanning.dart',
             'lib/screens/game_screen/my_games_list.dart', 'test', 'pubspec.yaml', 'pubspec.lock']
    run('git', 'archive', '--format=zip', '--output=' + str(LOGS / 'source-review.zip'), 'HEAD', *paths)
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    demand(sha == os.environ['GITHUB_SHA'], 'Build checkout does not match the triggering SHA')
    (LOGS / 'source-commit.txt').write_text(sha + '\n')


def generate_plugin_registrant(ios: Path) -> None:
    # Dependency resolution ran before the iOS scaffold existed. Let Flutter
    # generate the real registrant from NeoStation's locked plugin graph now;
    # --config-only --no-pub alone does not create these native source files.
    run('flutter', 'pub', 'get', '--enforce-lockfile')
    for name in ('GeneratedPluginRegistrant.h', 'GeneratedPluginRegistrant.m'):
        path = ios / 'Runner' / name
        demand(path.is_file() and path.stat().st_size > 0,
               f'Flutter did not generate the native plugin registrant: {path}')


def scaffold() -> None:
    # Never run flutter create in the source tree: it rewrites pubspec.lock and
    # creates a counter-app widget test unrelated to NeoStation.
    ios = ROOT / 'ios'
    if not ios.exists():
        with tempfile.TemporaryDirectory(prefix='neostation-ios-host-') as temp:
            host = Path(temp) / 'neostation'
            run('flutter', 'create', '--no-pub', '--platforms=ios', '--org',
                'com.neogamelab', '--project-name', 'neostation', str(host))
            shutil.copytree(host / 'ios', ios)
    # CocoaPods is intentionally retained; all existing Flutter plugins use the
    # same integration. The helper's separate target is added by the configurator.
    podfile = ios / 'Podfile'
    if not podfile.is_file():
        podfile.write_text(r'''platform :ios, '17.4'
ENV['COCOAPODS_DISABLE_STATS'] = 'true'
project 'Runner', { 'Debug' => :debug, 'Profile' => :release, 'Release' => :release }
def flutter_root
  path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  raise "Missing #{path}; run flutter build ios --config-only" unless File.exist?(path)
  File.foreach(path) do |line|
    match = line.match(/FLUTTER_ROOT\=(.*)/)
    return match[1].strip if match
  end
  raise 'FLUTTER_ROOT not found'
end
require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)
flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!
  use_modular_headers!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
''', encoding='utf-8')
    info_path = ios / 'Runner/Info.plist'
    info = plist(info_path)
    info['CFBundleDisplayName'] = 'NeoStation iOS'
    write_plist(info_path, info)
    generate_plugin_registrant(ios)
    run('git', 'diff', '--exit-code', '--', 'pubspec.yaml', 'pubspec.lock')


def restore_stik(archive: Path) -> None:
    demand(file_sha256(archive) == STIK_SHA, 'StikJIT release SHA-256 mismatch')
    with tempfile.TemporaryDirectory(prefix='stikjit-1.5.0-') as temp:
        with zipfile.ZipFile(archive) as z:
            demand(z.testzip() is None, 'Corrupt StikJIT ZIP')
            for name in z.namelist():
                demand(not name.startswith('/') and '..' not in name.split('/'), 'Unsafe framework ZIP member')
            z.extractall(temp)
        roots = list(Path(temp).rglob('StikJIT.xcframework'))
        demand(len(roots) == 1, 'Expected exactly one StikJIT XCFramework')
        original = roots[0]
        for interface in original.rglob('*.swiftinterface'):
            text = interface.read_text()
            # StikJIT is both the module and enum name in the distributed 1.5.0
            # interface. Keep the established qualification repair, not its API.
            for name in ('DDIPaths', 'DeveloperDiskImageService', 'StikJITError'):
                text = text.replace('StikJIT.' + name, name)
            text = text.replace('StikJIT.StikJIT.', 'StikJIT.')
            interface.write_text(text)
        device = original / 'ios-arm64/StikJIT.framework'
        binary = device / 'StikJIT'
        demand(binary.is_file(), 'Device slice of StikJIT is missing')
        image = macho(binary.read_bytes())
        demand(image['platform'] == 2, 'StikJIT slice is not iOS arm64')
        info_path = device / 'Info.plist'
        info = plist(info_path) if info_path.is_file() else {}
        info.update({'CFBundleExecutable': 'StikJIT', 'CFBundleIdentifier': 'com.stik.StikJIT',
                     'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'StikJIT',
                     'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '1.5.0',
                     'CFBundleVersion': '1', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
                     'MinimumOSVersion': '17.4', 'UIDeviceFamily': [1, 2]})
        write_plist(info_path, info)
        for package in ('stikjit_bridge', 'dolphin_jit_helper'):
            dest = ROOT / 'packages' / package / 'ios/Frameworks/StikJIT.xcframework'
            if dest.exists():
                shutil.rmtree(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(original, dest)
            (dest / 'ios-arm64/StikJIT.framework/StikJIT').chmod(0o755)
        (LOGS / 'stikjit-release.json').write_text(json.dumps({
            'release': '1.5.0', 'archiveSha256': STIK_SHA, 'binarySha256': file_sha256(binary),
            'dependencies': image['dependencies'], 'platform': image['platform'],
        }, indent=2) + '\n')


def core_framework(source: Path) -> None:
    binary = source / 'build-iphoneos-Release/Source/iOS/Library/libdolphin.dylib'
    demand(binary.is_file(), 'Pinned Dolphin build produced no dylib')
    framework = ROOT / 'packages/dolphin_internal_bridge/ios/Frameworks/DolphinCore.framework'
    if framework.exists():
        shutil.rmtree(framework)
    framework.mkdir(parents=True)
    out = framework / 'DolphinCore'
    shutil.copy2(binary, out)
    run('install_name_tool', '-id', '@rpath/DolphinCore.framework/DolphinCore', str(out))
    out.chmod(0o755)
    write_plist(framework / 'Info.plist', {
        'CFBundleExecutable': 'DolphinCore', 'CFBundleIdentifier': 'com.neogamelab.neostation.DolphinCore',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'DolphinCore',
        'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': os.environ['BUILD_NUMBER'], 'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'MinimumOSVersion': '17.4',
    })
    image = macho(out.read_bytes())
    demand(image['platform'] == 2, 'Dolphin build is not an iOS device image')
    demand(BRIDGE <= set(image['definedSymbols']), 'Dolphin ABI export missing')
    (LOGS / 'dolphin-exports.txt').write_text('\n'.join(image['definedSymbols']) + '\n')
    (LOGS / 'dolphin-dependencies.json').write_text(json.dumps(image['dependencies'], indent=2) + '\n')
    sys_dest = ROOT / 'ios/Runner/Sys'
    if sys_dest.exists():
        shutil.rmtree(sys_dest)
    shutil.copytree(source / 'Data/Sys', sys_dest)
    (LOGS / 'dolphin-revision.txt').write_text(os.environ['DOLPHIN_SHA'] + '\n')
    with zipfile.ZipFile(LOGS / 'native-source.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        for rel in ('Source/iOS/Library/NeoStationBridge.mm', 'Source/iOS/Library/CMakeLists.txt',
                    'Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp'):
            z.write(source / rel, rel)


def configure_smoke() -> None:
    config = ROOT / 'build-utils/configure_dolphin_ios_v2.py'
    # Syntax-check the embedded Ruby program before opening the real project.
    import ast
    tree = ast.parse(config.read_text())
    ruby = next(n.value.value for n in ast.walk(tree) if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'ruby' for t in n.targets)
                and isinstance(n.value, ast.Constant))
    syntax = LOGS / 'configure-helper-syntax.rb'
    syntax.write_text(ruby)
    run('bundle', 'exec', 'ruby', '-c', str(syntax))
    versions = subprocess.check_output(['bundle', 'exec', 'ruby', '-rxcodeproj', '-rrbconfig', '-e',
        'puts "ruby=#{RUBY_VERSION}"; puts "ruby.path=#{RbConfig.ruby}"; '
        'puts "xcodeproj=#{Xcodeproj::VERSION}"; puts "xcodeproj.path=#{Gem.loaded_specs.fetch("xcodeproj").full_gem_path}"'], text=True)
    print(versions)
    (LOGS / 'xcodeproj-version.txt').write_text(versions)
    checked = [ROOT / 'ios/Runner.xcodeproj/project.pbxproj', ROOT / 'ios/Podfile',
               ROOT / 'ios/Runner/Info.plist', ROOT / 'ios/Runner/Runner.entitlements']
    hashes = []
    for attempt in range(3):
        output = subprocess.check_output(['python3', str(config)], cwd=ROOT, text=True)
        (LOGS / f'xcodeproj-configure-{attempt + 1}.txt').write_text(output)
        print(output)
        hashes.append({str(p.relative_to(ROOT)): file_sha256(p) for p in checked})
    demand(hashes[0] == hashes[1] == hashes[2], 'Xcode configurator is not idempotent')
    (LOGS / 'xcodeproj-idempotence.json').write_text(json.dumps({'runs': 3, 'passed': True, 'hashes': hashes}, indent=2) + '\n')


def package() -> None:
    products = ROOT / 'build/ios/DolphinDerivedData/Build/Products/Release-iphoneos'
    apps = list(products.glob('*.app'))
    demand(len(apps) == 1, 'Xcode did not produce exactly one application')
    stage = ROOT / 'build/ios/dolphin-unsigned'
    if stage.exists():
        shutil.rmtree(stage)
    app = stage / 'Payload/NeoStation.app'
    shutil.copytree(apps[0], app, symlinks=True)
    shared = app / 'Frameworks/StikJIT.framework'
    demand(shared.is_dir(), 'Shared StikJIT host framework was not embedded by CocoaPods')
    duplicates = []
    for other in app.rglob('StikJIT.framework'):
        if other == shared:
            continue
        demand(other.parent.name == 'Frameworks' and other.parent.parent.name == 'DolphinJITHelper.appex', 'Unexpected additional StikJIT owner')
        demand(file_sha256(other / 'StikJIT') == file_sha256(shared / 'StikJIT'), 'Different StikJIT copies: refusing to discard one')
        helper = other.parent.parent
        executable = helper / plist(helper / 'Info.plist')['CFBundleExecutable']
        image = macho(executable.read_bytes())
        demand('@executable_path/../../Frameworks' in image['rpaths'], 'Helper cannot resolve the shared StikJIT')
        duplicates.append(str(other.relative_to(app)))
        shutil.rmtree(other)
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    ipa = dist / (os.environ['IPA_NAME'] + '.ipa')
    if ipa.exists():
        ipa.unlink()
    run('/usr/bin/zip', '-qry', str(ipa), 'Payload', cwd=stage)
    run('unzip', '-tq', str(ipa))
    report = validate(ipa)
    report.update({'branch': 'test/dolphin-internal-engine-isolated-v3',
                   'commit': os.environ['GITHUB_SHA'], 'buildNumber': os.environ['BUILD_NUMBER'],
                   'runId': os.environ['GITHUB_RUN_ID'], 'dolphinRevision': os.environ['DOLPHIN_SHA'],
                   'removedIdenticalHelperFrameworkCopies': duplicates,
                   'xcodeprojIdempotence': json.loads((LOGS / 'xcodeproj-idempotence.json').read_text()),
                   'stikjitRelease': json.loads((LOGS / 'stikjit-release.json').read_text())})
    (dist / 'dolphin-build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    (dist / (ipa.name + '.sha256')).write_text(report['sha256'] + '  ' + ipa.name + '\n')
    shutil.copy2(ROOT / 'ios/Runner/Runner.entitlements', dist / 'NeoStation-signing.entitlements')
    print(json.dumps({k: report[k] for k in ('ipa', 'bytes', 'sha256', 'signatureState', 'structuralValidation')}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['snapshot', 'scaffold', 'stik', 'framework', 'configure', 'package'])
    parser.add_argument('path', nargs='?', type=Path)
    args = parser.parse_args()
    LOGS.mkdir(parents=True, exist_ok=True)
    if args.command == 'stik':
        demand(args.path is not None, 'Archive path required')
        restore_stik(args.path)
    elif args.command == 'framework':
        demand(args.path is not None, 'Pinned source path required')
        core_framework(args.path)
    else:
        {'snapshot': source_snapshot, 'scaffold': scaffold, 'configure': configure_smoke, 'package': package}[args.command]()


if __name__ == '__main__':
    main()
