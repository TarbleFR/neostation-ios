#!/usr/bin/env python3
"""Run NeoStation's embedded libretro session with real cores in the iOS Simulator (macOS).

`fetch` downloads the pinned test inputs: RetroArch's MoltenVK simulator
slice (same RetroArch revision as the delivered device slice), the
pspautotests GPU test program `simple.prx` and the ftpd 3DS homebrew
`ftpd.3dsx`. Every file is checked against its pinned identity.

`run` builds test/libretro_simulator/probe.m with the libretro bridge
sources into a small UIKit app and embeds:
- PPSSPP and Azahar from the cores artifact the delivery pins, with their
  Mach-O platform switched from iOS (2) to iOS Simulator (7) - no other
  byte changes - and signed ad hoc;
- the MoltenVK simulator slice;
- the NeoTest core of test/libretro_host, built for the simulator;
- PPSSPP's system files, and the content: NeoTest's game, simple.prx, an
  ISO built here around simple.prx (PSP_GAME/SYSDIR/EBOOT.BIN, PARAM.SFO,
  "PSP GAME" system id: the ISO path of real games) and ftpd.3dsx.
It boots a simulator, runs the scenarios (launch like the plugin, run,
"Quit game", relaunch) and checks each outcome, the session journal's
teardown order and that the game view is gone. Evidence (results, progress
log, journals, simulator log, crash reports) goes to --evidence.

With --sources (another bridge tree, e.g. the commit before a fix) and
--expect unfixed, it records whether that tree's process dies while a
scenario is being closed; it never fails on that outcome.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'packages/libretro_internal_bridge/ios'
CATALOG = ROOT / 'lib/services/libretro_core_catalog.dart'
TARGET = 'arm64-apple-ios17.4-simulator'
BUNDLE_ID = 'com.neostation.libretro.probe'
DEFINES = ('GLES_SILENCE_DEPRECATION=1', 'COREVIDEO_SILENCE_GL_DEPRECATION=1', 'VK_USE_PLATFORM_METAL_EXT=1',
           'VK_NO_PROTOTYPES=1', 'RC_CLIENT_SUPPORTS_HASH=1')
FRAMEWORKS = ('UIKit', 'Foundation', 'Metal', 'QuartzCore', 'AVFoundation', 'GameController', 'OpenGLES',
              'CoreVideo', 'Security', 'ImageIO', 'CoreGraphics')
REAL_CORES = ('ppsspp', 'azahar')
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
PLATFORM_IOS_SIMULATOR = 7

RETROARCH_REVISION = 'df16ef193cbe385b87e8a1cf27b66da35bf3c0e0'
MOLTENVK_SIMULATOR = 'pkg/apple/Frameworks/MoltenVK.xcframework/ios-arm64_x86_64-simulator/MoltenVK.framework'
PSPAUTOTESTS_REVISION = 'cd3d49c4c5d8fa4d84779a216270db7408842017'
# name: (url, git blob SHA-1 or None, size, SHA-256 or None)
INPUTS = {
    'MoltenVK.framework/MoltenVK': (
        f'https://raw.githubusercontent.com/libretro/RetroArch/{RETROARCH_REVISION}/{MOLTENVK_SIMULATOR}/MoltenVK',
        'ded496ced533a5397532741e600ea75be97dda41', 13804080, None),
    'MoltenVK.framework/Info.plist': (
        f'https://raw.githubusercontent.com/libretro/RetroArch/{RETROARCH_REVISION}/{MOLTENVK_SIMULATOR}/Info.plist',
        '231e8d6e5dde1cb651564d25d6443ef507bd89e4', 728, None),
    'simple.prx': (
        f'https://raw.githubusercontent.com/hrydgard/pspautotests/{PSPAUTOTESTS_REVISION}/tests/gpu/simple/simple.prx',
        'dd010448eb8d19f91e409fc280023f823b5fc209', 133594, None),
    'ftpd.3dsx': (
        'https://github.com/mtheall/ftpd/releases/download/v3.2.1/ftpd.3dsx', None, 1408252, None),
}

# Scenarios run in this order; a process that dies stops the rest.
SCENARIOS = [
    {'name': 'neotest-1', 'core': 'neotest', 'content': 'content/Test Game.ntc', 'console': 'gb', 'expect': 'run'},
    {'name': 'neotest-2', 'core': 'neotest', 'content': 'content/Test Game.ntc', 'console': 'gb', 'expect': 'run'},
    {'name': 'neotest-startup-stop', 'core': 'neotest', 'content': 'content/Test Game.ntc', 'console': 'gb',
     'lockedOptions': {'neotest_shutdown_frame': '3'}, 'expect': 'core-stopped'},
    {'name': 'ppsspp-prx', 'core': 'ppsspp', 'content': 'content/simple.prx', 'console': 'psp', 'expect': 'run'},
    {'name': 'ppsspp-iso-1', 'core': 'ppsspp', 'content': 'content/probe.iso', 'console': 'psp', 'expect': 'run'},
    {'name': 'ppsspp-iso-2', 'core': 'ppsspp', 'content': 'content/probe.iso', 'console': 'psp', 'expect': 'run'},
    {'name': 'azahar-1', 'core': 'azahar', 'content': 'content/ftpd.3dsx', 'console': '3ds', 'expect': 'run',
     'runSeconds': 4.0},
    {'name': 'azahar-2', 'core': 'azahar', 'content': 'content/ftpd.3dsx', 'console': '3ds', 'expect': 'run',
     'runSeconds': 4.0},
]
# Journal lines of a closed session, in the order RetroArch tears a core down.
TEARDOWN_ORDER = (
    'teardown: started',
    'teardown: context_destroy called',
    'teardown: context_destroy returned',
    'teardown: retro_unload_game called',
    'teardown: retro_unload_game returned',
    'teardown: retro_deinit called',
    'teardown: retro_deinit returned',
    'teardown: releasing the',
    'teardown: renderer released',
    'teardown: dlclose called',
    'teardown: dlclose returned',
    'stop: game view dismissed, returning to NeoStation',
)


def run(arguments, **options):
    print('+ ' + ' '.join(str(argument) for argument in arguments), flush=True)
    return subprocess.run([str(argument) for argument in arguments], check=True, **options)


def output(arguments):
    return subprocess.run([str(argument) for argument in arguments], check=True, capture_output=True,
                          text=True).stdout


def git_blob_sha1(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


# --- fetch ---------------------------------------------------------------

def fetch(destination):
    destination.mkdir(parents=True, exist_ok=True)
    identities = {}
    for name, (url, blob, size, digest) in INPUTS.items():
        request = urllib.request.Request(url, headers={'User-Agent': 'NeoStation-CI'})
        with urllib.request.urlopen(request, timeout=300) as response:
            data = response.read()
        if len(data) != size:
            raise SystemExit(f'{name}: {len(data)} bytes, pinned {size}')
        if blob is not None and git_blob_sha1(data) != blob:
            raise SystemExit(f'{name}: git blob {git_blob_sha1(data)}, pinned {blob}')
        sha256 = hashlib.sha256(data).hexdigest()
        if digest is not None and sha256 != digest:
            raise SystemExit(f'{name}: SHA-256 {sha256}, pinned {digest}')
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        identities[name] = {'url': url, 'bytes': size, 'sha256': sha256, 'gitBlob': git_blob_sha1(data)}
        print(f'{name}: {size} bytes, SHA-256 {sha256}', flush=True)
    (destination / 'identities.json').write_text(json.dumps(identities, indent=2) + '\n')


# --- catalog -------------------------------------------------------------

def catalog_block(text, kind, identifier):
    match = re.search(rf"^    '{re.escape(identifier)}': {kind}\((.*?)^    \),", text, flags=re.M | re.S)
    if match is None:
        raise SystemExit(f'{kind} {identifier} not found in {CATALOG.relative_to(ROOT)}')
    return match.group(1)


def string_map(block, field):
    match = re.search(rf'{field}: \{{(.*?)\}}', block, flags=re.S)
    if match is None:
        return {}
    return dict(re.findall(r"'([^']+)':\s*'([^']*)'", match.group(1)))


def core_settings(text, core):
    block = catalog_block(text, 'LibretroCore', core)
    context = re.search(r'preferredHardwareContext: LibretroHardwareContext\.(\w+)', block)
    contexts = {'none': 0, 'openGLES3': 4, 'vulkan': 6}
    return {
        'preferredHardwareContext': contexts[context.group(1)] if context else 0,
        'optionDefaults': string_map(block, 'optionDefaults'),
        'noJitOverrides': string_map(block, 'noJitOverrides'),
        'lockedOptions': string_map(block, 'lockedOptions'),
    }


def console_geometry(text, console):
    block = catalog_block(text, 'LibretroConsole', console)
    name = re.search(r"name: '([^']+)'", block).group(1)
    width = int(re.search(r'width: (\d+)', block).group(1))
    height = int(re.search(r'height: (\d+)', block).group(1))
    entry = {'size': [width, height]}
    regions = dict((key, [float(value) for value in values.split(',')])
                   for key, values in re.findall(r"'(\w+)': \[([^\]]+)\]", block))
    if regions:
        entry['regions'] = regions
    return name, entry


# --- content -------------------------------------------------------------

def param_sfo(entries):
    """A PSP PARAM.SFO: text values UTF-8 (0x0204), numbers int32 (0x0404)."""
    keys = b''
    data = b''
    index = b''
    for key, value in sorted(entries.items()):
        key_offset = len(keys)
        keys += key.encode() + b'\0'
        if isinstance(value, int):
            payload = struct.pack('<I', value)
            index += struct.pack('<HHIII', key_offset, 0x0404, 4, 4, len(data))
        else:
            raw = value.encode() + b'\0'
            capacity = (len(raw) + 3) & ~3
            payload = raw.ljust(capacity, b'\0')
            index += struct.pack('<HHIII', key_offset, 0x0204, len(raw), capacity, len(data))
        data += payload
    keys = keys.ljust((len(keys) + 3) & ~3, b'\0')
    key_table = 20 + len(index)
    data_table = key_table + len(keys)
    return struct.pack('<4sIIII', b'\0PSF', 0x101, key_table, data_table, len(entries)) + index + keys + data


def build_iso(program, output_path, work):
    """An ISO 9660 image like a PSP disc: PSP_GAME/PARAM.SFO and
    PSP_GAME/SYSDIR/EBOOT.BIN, system id "PSP GAME"."""
    staging = work / 'iso'
    (staging / 'PSP_GAME/SYSDIR').mkdir(parents=True)
    shutil.copyfile(program, staging / 'PSP_GAME/SYSDIR/EBOOT.BIN')
    (staging / 'PSP_GAME/PARAM.SFO').write_bytes(param_sfo({
        'BOOTABLE': 1, 'CATEGORY': 'UG', 'DISC_ID': 'NEOS00001', 'DISC_NUMBER': 1, 'DISC_TOTAL': 1,
        'DISC_VERSION': '1.00', 'PARENTAL_LEVEL': 1, 'PSP_SYSTEM_VER': '1.00', 'REGION': 0x8000,
        'TITLE': 'NeoStation probe',
    }))
    target = work / 'probe.iso'
    run(['hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'NEOPROBE', '-o', target, staging])
    image = bytearray(target.read_bytes())
    if image[0x8001:0x8006] != b'CD001':
        raise SystemExit('hdiutil did not produce an ISO 9660 primary volume descriptor')
    image[0x8008:0x8028] = b'PSP GAME'.ljust(32, b' ')
    output_path.write_bytes(image)


# --- build ---------------------------------------------------------------

def sdk_path():
    return output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()


def compile_probe(sources, sdk, work, app):
    includes = [sources / 'Classes', sources / 'ThirdParty/include', sources / 'ThirdParty/include/libretro',
                sources / 'ThirdParty/rcheevos/include', sources / 'ThirdParty/rcheevos/src']
    base = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', TARGET, '-isysroot', sdk, '-O1',
            '-Wno-deprecated-declarations']
    for include in includes:
        base += ['-I', str(include)]
    for define in DEFINES:
        base += ['-D', define]
    units = [path for path in sorted((sources / 'Classes').glob('*.m')) if path.name != 'LibretroInternalBridgePlugin.m']
    units += sorted((sources / 'ThirdParty/rcheevos/src').rglob('*.c'))
    units.append(ROOT / 'test/libretro_simulator/probe.m')
    objects = []
    for index, unit in enumerate(units):
        target = work / f'{index:03d}_{unit.stem}.o'
        arguments = list(base)
        if unit.suffix == '.m':
            arguments += ['-fobjc-arc', '-fmodules']
        result = subprocess.run(arguments + ['-c', str(unit), '-o', str(target)], capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr, flush=True)
            raise SystemExit(f'simulator compilation failed: {unit}')
        objects.append(target)
    print(f'compiled {len(units)} sources for the simulator', flush=True)
    link = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', TARGET, '-isysroot', sdk, '-fobjc-arc',
            *(str(item) for item in objects)]
    for framework in FRAMEWORKS:
        link += ['-framework', framework]
    link += ['-lz', '-Wl,-rpath,@executable_path/Frameworks', '-o', str(app / 'Probe')]
    run(link)


def build_neotest(sdk, frameworks):
    target = frameworks / 'neotest_libretro.framework'
    target.mkdir(parents=True)
    run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', TARGET, '-isysroot', sdk, '-dynamiclib', '-O1',
         '-I', BRIDGE / 'ThirdParty/include/libretro', ROOT / 'test/libretro_host/test_core.c',
         '-install_name', '@rpath/neotest_libretro.framework/neotest_libretro', '-o', target / 'neotest_libretro'])
    framework_plist(target, 'neotest_libretro')


def framework_plist(target, executable):
    with open(target / 'Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleExecutable': executable, 'CFBundleIdentifier': f'{BUNDLE_ID}.{executable}',
                       'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                       'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'MinimumOSVersion': '17.4'}, handle)


def retarget_to_simulator(binary):
    """Switches LC_BUILD_VERSION's platform from iOS to iOS Simulator."""
    data = bytearray(binary.read_bytes())
    magic, _, _, _, count = struct.unpack_from('<IiiII', data, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f'{binary}: not a thin 64-bit Mach-O')
    cursor = 32
    patched = 0
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, cursor)
        if command == LC_BUILD_VERSION:
            platform = struct.unpack_from('<I', data, cursor + 8)[0]
            if platform != PLATFORM_IOS:
                raise SystemExit(f'{binary}: platform {platform}, expected iOS')
            struct.pack_into('<I', data, cursor + 8, PLATFORM_IOS_SIMULATOR)
            patched += 1
        cursor += size
    if patched != 1:
        raise SystemExit(f'{binary}: {patched} LC_BUILD_VERSION commands patched, expected 1')
    binary.write_bytes(data)
    binary.chmod(0o755)


def assemble(args, sources, work):
    sdk = sdk_path()
    app = work / 'Probe.app'
    frameworks = app / 'Frameworks'
    frameworks.mkdir(parents=True)
    compile_probe(sources, sdk, work, app)
    build_neotest(sdk, frameworks)
    cores = Path(args.cores)
    for core in REAL_CORES:
        source = cores / 'Frameworks' / f'{core}_libretro.framework'
        target = frameworks / source.name
        shutil.copytree(source, target)
        retarget_to_simulator(target / f'{core}_libretro')
        framework_plist(target, f'{core}_libretro')
    inputs = Path(args.inputs)
    shutil.copytree(inputs / 'MoltenVK.framework', frameworks / 'MoltenVK.framework')
    (frameworks / 'MoltenVK.framework/MoltenVK').chmod(0o755)
    shutil.copytree(cores / 'LibretroSystem', app / 'LibretroSystem')
    content = app / 'content'
    content.mkdir()
    (content / 'Test Game.ntc').write_bytes(bytes(range(1, 101)))
    shutil.copyfile(inputs / 'simple.prx', content / 'simple.prx')
    shutil.copyfile(inputs / 'ftpd.3dsx', content / 'ftpd.3dsx')
    build_iso(inputs / 'simple.prx', content / 'probe.iso', work)
    catalog = CATALOG.read_text(encoding='utf-8')
    geometry = {}
    names = {}
    for console in ('gb', 'psp', '3ds'):
        names[console], geometry[console] = console_geometry(catalog, console)
    scenarios = []
    for scenario in SCENARIOS:
        if args.only and scenario['name'] not in args.only:
            continue
        entry = dict(scenario)
        if scenario['core'] in REAL_CORES:
            entry.update(core_settings(catalog, scenario['core']))
        entry['consoleName'] = names[scenario['console']]
        scenarios.append(entry)
    config = {'source': args.label, 'consoleGeometry': geometry, 'scenarios': scenarios}
    (app / 'probe-config.json').write_text(json.dumps(config, indent=2) + '\n')
    with open(app / 'Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'Probe',
                       'CFBundleName': 'Libretro Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                       'CFBundleShortVersionString': '1.0', 'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '17.4',
                       'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
                       'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
                       'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeLeft',
                                                            'UIInterfaceOrientationLandscapeRight',
                                                            'UIInterfaceOrientationPortrait']}, handle)
    for framework in sorted(frameworks.iterdir()):
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', framework])
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', app])
    return app, scenarios


# --- simulator -----------------------------------------------------------

def pick_device():
    listing = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    candidates = []
    for runtime, devices in listing['devices'].items():
        match = re.search(r'iOS-(\d+)-(\d+)', runtime)
        if match is None:
            continue
        for device in devices:
            if device.get('isAvailable') and device['name'].startswith('iPhone'):
                candidates.append(((int(match.group(1)), int(match.group(2))), device['name'], device['udid']))
    if not candidates:
        raise SystemExit('No iPhone simulator available')
    candidates.sort(reverse=True)
    version, name, udid = candidates[0]
    print(f'simulator: {name}, iOS {version[0]}.{version[1]} ({udid})', flush=True)
    return udid, f'{name} iOS {version[0]}.{version[1]}'


def probe_pid(console_path):
    """`simctl launch` prints "<bundle id>: <pid>" first."""
    try:
        match = re.search(rf'{re.escape(BUNDLE_ID)}: (\d+)', console_path.read_text(errors='replace'))
    except OSError:
        return None
    return int(match.group(1)) if match else None


def run_in_simulator(app, evidence, timeout):
    udid, description = pick_device()
    # A fresh device for every run: nothing left by a previous probe.
    subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
    run(['xcrun', 'simctl', 'erase', udid])
    subprocess.run(['xcrun', 'simctl', 'boot', udid], capture_output=True)
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=600)
    run(['xcrun', 'simctl', 'install', udid, app])
    data = Path(output(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE_ID, 'data']).strip())
    documents = data / 'Documents'
    console_path = evidence / 'probe-console.log'
    console = open(console_path, 'w')
    launched_at = time.time()
    process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', udid,
                                BUNDLE_ID], stdout=console, stderr=subprocess.STDOUT)
    finished = False
    exited = False
    silent_sampled = False
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (documents / 'probe.json').is_file():
            finished = True
            break
        if process.poll() is not None:
            exited = True
            break
        progress = documents / 'probe-progress.log'
        if not silent_sampled and time.time() - launched_at > 120 and not progress.is_file():
            # Launched but silent: record where its threads are.
            silent_sampled = True
            pid = probe_pid(console_path)
            print(f'the probe wrote no progress in 120 s (pid {pid}); sampling it', flush=True)
            if pid:
                subprocess.run(['sample', str(pid), '3', '-file', str(evidence / 'probe-silent-sample.txt')],
                               capture_output=True)
        time.sleep(1)
    if not finished and not exited:
        pid = probe_pid(console_path)
        if pid:
            subprocess.run(['sample', str(pid), '3', '-file', str(evidence / 'probe-timeout-sample.txt')],
                           capture_output=True)
    time.sleep(1)
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, BUNDLE_ID], capture_output=True)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
    console.close()
    for name in ('probe.json', 'probe-partial.json', 'probe-progress.log'):
        if (documents / name).is_file():
            shutil.copyfile(documents / name, evidence / name)
    logs = documents / 'Libretro/Logs'
    if logs.is_dir():
        shutil.copytree(logs, evidence / 'Logs', dirs_exist_ok=True)
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    for report in sorted(reports.glob('Probe*')) if reports.is_dir() else []:
        if report.stat().st_mtime >= launched_at - 5:
            shutil.copyfile(report, evidence / report.name)
    with open(evidence / 'simulator-system.log', 'w') as handle:
        subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '20m', '--style', 'compact',
                        '--predicate', 'process == "Probe"'], stdout=handle, stderr=subprocess.STDOUT)
    subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
    return {'simulator': description, 'finished': finished, 'exitedEarly': exited and not finished,
            'seconds': round(time.time() - launched_at, 1)}


# --- evaluation ----------------------------------------------------------

def journal_order_problems(journal):
    lines = journal.splitlines()
    position = 0
    for step in TEARDOWN_ORDER:
        found = next((index for index in range(position, len(lines)) if step in lines[index]), None)
        if found is None:
            return f'journal lacks "{step}" after the previous teardown step'
        position = found + 1
    if not any(line == 'END closed' for line in lines[position:]):
        return 'journal lacks its END closed line'
    return None


def evaluate(report, scenarios):
    results = {result['name']: result for result in report.get('results', [])}
    problems = []
    for scenario in scenarios:
        name = scenario['name']
        result = results.get(name)
        if result is None:
            problems.append(f'{name}: no result (the process died or timed out before it; see probe-progress.log)')
            continue
        launch = result.get('launch', {})
        if result.get('timeout'):
            problems.append(f'{name}: the launch never answered')
            continue
        if scenario['expect'] == 'run':
            if not launch.get('success'):
                problems.append(f"{name}: launch failed {launch.get('code')}: {launch.get('message')}")
                continue
            if not result.get('stopped') or not result.get('ended'):
                problems.append(f'{name}: closing did not complete (stopped={result.get("stopped")}, '
                                f'ended={result.get("ended")})')
            if result.get('presentedAfterStop') or result.get('presentedAtEnd') or result.get('activeAfterStop'):
                problems.append(f'{name}: the game view or session outlived "Quit game"')
            problem = journal_order_problems(result.get('journal', ''))
            if problem:
                problems.append(f'{name}: {problem}')
        elif scenario['expect'] == 'core-stopped':
            if launch.get('success') or launch.get('code') != 'LIBRETRO_CORE_STOPPED':
                problems.append(f"{name}: expected a LIBRETRO_CORE_STOPPED launch failure, got "
                                f"{launch.get('success')} {launch.get('code')}")
            elif 'neotest boot failed: simulated' not in launch.get('message', ''):
                problems.append(f"{name}: the failure does not quote the core's error: {launch.get('message')}")
            if result.get('presentedAtEnd') or result.get('activeAfterStop'):
                problems.append(f'{name}: the game view or session stayed after the failure')
            if 'END launch failed LIBRETRO_CORE_STOPPED' not in result.get('journal', ''):
                problems.append(f'{name}: the journal does not end with the launch failure')
    return problems


def summarise(report, scenarios):
    results = {result['name']: result for result in report.get('results', [])}
    for scenario in scenarios:
        result = results.get(scenario['name'])
        if result is None:
            print(f"  {scenario['name']:22} no result", flush=True)
            continue
        launch = result.get('launch', {})
        print(f"  {scenario['name']:22} launch={'ok' if launch.get('success') else launch.get('code')} "
              f"renderer={launch.get('hardwareRendering') or '-'} launch={result.get('launchSeconds', 0):.1f}s "
              f"stop={result.get('stopSeconds', 0):.1f}s stopped={result.get('stopped', False)} "
              f"ended={result.get('ended', False)}", flush=True)
        if not launch.get('success'):
            print(f"    message: {launch.get('message')}", flush=True)


def command_run(args):
    if sys.platform != 'darwin':
        raise SystemExit('The simulator probe runs on macOS.')
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    sources = Path(args.sources) if args.sources else BRIDGE
    with tempfile.TemporaryDirectory(prefix='libretro-probe-') as temporary:
        app, scenarios = assemble(args, sources, Path(temporary))
        outcome = run_in_simulator(app, evidence, args.timeout)
    report_path = evidence / ('probe.json' if (evidence / 'probe.json').is_file() else 'probe-partial.json')
    report = json.loads(report_path.read_text()) if report_path.is_file() else {'results': []}
    progress = (evidence / 'probe-progress.log').read_text() if (evidence / 'probe-progress.log').is_file() else ''
    outcome['label'] = args.label
    (evidence / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print(f"\nProbe on {outcome['simulator']} ({args.label}): finished={outcome['finished']} "
          f"exitedEarly={outcome['exitedEarly']} in {outcome['seconds']} s", flush=True)
    summarise(report, scenarios)
    if args.expect == 'unfixed':
        # Informational: does this tree's process die while closing a game?
        died_closing = [scenario['name'] for scenario in scenarios
                        if f"{scenario['name']}: stop requested" in progress
                        and f"{scenario['name']}: stopped" not in progress]
        if died_closing and not outcome['finished']:
            print(f'REPRODUCED with {args.label}: the process died while closing {", ".join(died_closing)}')
        else:
            print(f'NOT REPRODUCED with {args.label} in the simulator (finished={outcome["finished"]})')
        return
    problems = evaluate(report, scenarios)
    if not outcome['finished']:
        problems.insert(0, 'the probe did not finish (process ended or timed out); last progress lines:\n'
                        + '\n'.join(progress.splitlines()[-8:]))
    if problems:
        print('\nSimulator probe problems:', flush=True)
        for problem in problems:
            print('  - ' + problem, flush=True)
        raise SystemExit(f'{len(problems)} simulator probe problem(s)')
    print(f'All {len(scenarios)} simulator scenarios behaved as expected')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    fetch_parser = commands.add_parser('fetch')
    fetch_parser.add_argument('--into', required=True)
    run_parser = commands.add_parser('run')
    run_parser.add_argument('--cores', required=True, help='LibretroCores artifact (Frameworks/, LibretroSystem/)')
    run_parser.add_argument('--inputs', required=True, help='directory filled by `fetch`')
    run_parser.add_argument('--evidence', required=True)
    run_parser.add_argument('--sources', help='libretro bridge ios/ directory (default: this tree)')
    run_parser.add_argument('--label', default='this tree')
    run_parser.add_argument('--only', nargs='*', default=[])
    run_parser.add_argument('--expect', choices=('fixed', 'unfixed'), default='fixed')
    run_parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    if args.command == 'fetch':
        fetch(Path(args.into))
    else:
        command_run(args)


if __name__ == '__main__':
    main()
