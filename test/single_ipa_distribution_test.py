"""Exercise the four-extension IPA contract with synthetic Mach-O signatures.

These fixtures test embedded entitlement parsing, not certificate trust,
provisioning authorization or memory donation on an iPhone.
"""
from __future__ import annotations

import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))

import validate_single_ipa_distribution as validator
from configure_rpcs3_ios_v2 import REQUIRED_RUNTIME_ENTITLEMENTS

APP = 'Payload/NeoStation.app/'
DONOR = APP + 'PlugIns/NeoSwapDonor.appex/'
JIT_CONTRACTS = {
    'DolphinJITHelper.appex': {
        'bundleSuffix': '.dolphinjithelper',
        'principalClass': 'DolphinJITRequestHandler',
        'marker': 'NeoStationDolphinJITHelper',
    },
    'RPCS3JITHelper.appex': {
        'bundleSuffix': '.rpcs3jithelper',
        'principalClass': 'Rpcs3JITRequestHandler',
        'marker': 'NeoStationRPCS3JITHelper',
    },
    'ARMSX2JITHelper.appex': {
        'bundleSuffix': '.armsx2jithelper',
        'principalClass': 'Armsx2JITRequestHandler',
        'marker': 'NeoStationARMSX2JITHelper',
    },
}
JIT_HELPERS = set(JIT_CONTRACTS)
DONOR_IDENTITIES = {
    'NeoSwapDonor.appex': ('.neoswapdonor', '0'),
}
DONOR_CONTRACTS = {
    name: {'bundleSuffix': suffix, 'index': index,
           'principalClass': 'NeoSwapDonorRequestHandler',
           'marker': 'NeoStationNeoSwapDonor'}
    for name, (suffix, index) in DONOR_IDENTITIES.items()
}
DONOR_ENTITLEMENTS = {
    'get-task-allow': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.developer.kernel.increased-debugging-memory-limit': True,
}
DONOR_POINT = 'com.apple.ar.viewer'
DONOR_SERVICE = {'ServiceType': 'Application', '_MultipleInstances': True, '_ProcessType': 'App'}


def macho(entitlements: dict | None, cpu: int = 0x0100000C, filetype: int = 2) -> bytes:
    if entitlements is None:
        return struct.pack('<8I', 0xFEEDFACF, cpu, 0, filetype, 0, 0, 0, 0)
    xml = plistlib.dumps(entitlements)
    slot = struct.pack('>II', 0xFADE7171, len(xml) + 8) + xml
    signature = struct.pack('>III', 0xFADE0CC0, len(slot) + 20, 1)
    signature += struct.pack('>II', 5, 20) + slot
    header = struct.pack('<8I', 0xFEEDFACF, cpu, 0, filetype, 1, 16, 0, 0)
    return header + struct.pack('<4I', 0x1D, 16, 48, len(signature)) + signature


def fat_macho(slices: list[tuple[int, bytes]], wide: bool = False) -> bytes:
    stride = 32 if wide else 20
    offset = 8 + stride * len(slices)
    table = bytearray(struct.pack('>II', 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)))
    payload = bytearray()
    for cpu, data in slices:
        if wide:
            table += struct.pack('>IIQQII', cpu, 0, offset, len(data), 0, 0)
        else:
            table += struct.pack('>IIIII', cpu, 0, offset, len(data), 0)
        payload += data
        offset += len(data)
    return bytes(table + payload)


def complete_ipa_members() -> dict[str, bytes]:
    host = {
        'CFBundleExecutable': 'Runner',
        'CFBundleIdentifier': 'com.neogamelab.neostation',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '368',
        'CFBundleShortVersionString': '0.0.2',
    }
    members = {
        APP + 'Info.plist': plistlib.dumps(host),
        APP + 'Runner': macho(REQUIRED_RUNTIME_ENTITLEMENTS),
    }
    for name, contract in (JIT_CONTRACTS | DONOR_CONTRACTS).items():
        executable = name.removesuffix('.appex')
        info = {
            'CFBundleExecutable': executable,
            'CFBundleIdentifier': host['CFBundleIdentifier'] + contract['bundleSuffix'],
            'CFBundlePackageType': 'XPC!',
            'CFBundleVersion': host['CFBundleVersion'],
            'CFBundleShortVersionString': host['CFBundleShortVersionString'],
            'MinimumOSVersion': '17.4',
            contract['marker']: '1',
            'NSExtension': {
                'NSExtensionPointIdentifier': DONOR_POINT if name in DONOR_IDENTITIES else 'com.apple.share-services',
                'NSExtensionPrincipalClass': contract['principalClass'],
                'NSExtensionAttributes': {'NSExtensionActivationRule': 'FALSEPREDICATE'},
            },
        }
        if name in DONOR_IDENTITIES:
            info['NeoStationNeoSwapDonorIndex'] = contract['index']
            info['XPCService'] = dict(DONOR_SERVICE)
            info['NSExtension'].update(NSExtensionContextClass='NSExtensionContext',
                                       NSExtensionContextHostClass='NSExtensionContext')
        prefix = APP + 'PlugIns/' + name + '/'
        members[prefix + 'Info.plist'] = plistlib.dumps(info)
        entitlements = DONOR_ENTITLEMENTS if name in DONOR_IDENTITIES else None
        members[prefix + executable] = macho(entitlements)
    return members


class SingleIPADistributionTests(unittest.TestCase):
    def validate_members(self, members: dict[str, bytes]) -> dict:
        with tempfile.TemporaryDirectory(prefix='single-ipa-test-') as temp:
            ipa = Path(temp) / 'NeoStation.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                for path, data in members.items():
                    archive.writestr(path, data)
            return validator.validate(ipa)

    def reject(self, members: dict[str, bytes], reason: str) -> None:
        with self.assertRaisesRegex((validator.DistributionError, ValueError), reason):
            self.validate_members(members)

    def modify_info(self, members, prefix, change):
        info = plistlib.loads(members[prefix + 'Info.plist'])
        change(info)
        members[prefix + 'Info.plist'] = plistlib.dumps(info)

    def test_accepts_one_app_with_exact_original_helpers_and_one_donor_bundle(self):
        self.assertEqual(validator.EXPECTED_EXTENSIONS, JIT_CONTRACTS | DONOR_CONTRACTS)
        self.assertEqual(validator.REQUIRED_DONOR_ENTITLEMENTS, DONOR_ENTITLEMENTS)
        report = self.validate_members(complete_ipa_members())
        self.assertEqual(report['installationUnits'], 1)
        self.assertEqual({entry['bundle'] for entry in report['embeddedExtensions']},
                         JIT_HELPERS | set(DONOR_IDENTITIES))
        self.assertEqual(report['neoSwapDonorRequestedEntitlements'],
                         DONOR_ENTITLEMENTS)
        self.assertEqual(report['neoSwapDonorCount'], 1)
        self.assertIs(report['neoSwapDonorProcessInstancesValidated'], False)
        self.assertIs(report['neoSwapDonorEffectiveDeviceProfileValidated'], False)
        self.assertIs(report['deviceRuntimeTested'], False)
        self.assertEqual(len(report['nestedSigningOrder']), 5)
        self.assertEqual(report['nestedSigningOrder'][-1], 'NeoStation.app')

    def test_requires_each_of_the_four_extensions(self):
        for name in JIT_HELPERS | set(DONOR_IDENTITIES):
            with self.subTest(extension=name):
                prefix = APP + 'PlugIns/' + name + '/'
                members = {path: data for path, data in complete_ipa_members().items()
                           if not path.startswith(prefix)}
                self.reject(members, 'Unexpected app-extension set')

    def test_rejects_unexpected_extension(self):
        members = complete_ipa_members()
        members[APP + 'PlugIns/Other.appex/Info.plist'] = plistlib.dumps({})
        self.reject(members, 'Unexpected app-extension set')

    def test_rejects_retired_additional_donor_bundles(self):
        for index in range(2, 9):
            with self.subTest(index=index):
                members = complete_ipa_members()
                members[APP + f'PlugIns/NeoSwapDonor{index}.appex/Info.plist'] = plistlib.dumps({})
                self.reject(members, 'Unexpected app-extension set')

    def test_rejects_second_installable_app(self):
        members = complete_ipa_members()
        members['Payload/Other.app/Info.plist'] = plistlib.dumps({})
        self.reject(members, 'exactly one installable app')

    def test_rejects_each_donor_outside_host_plugins(self):
        for name in DONOR_IDENTITIES:
            with self.subTest(donor=name):
                prefix = APP + 'PlugIns/' + name + '/'
                members = {path.replace(prefix, name + '/'): data
                           for path, data in complete_ipa_members().items()}
                self.reject(members, 'Every app extension must remain nested')

    def test_preserves_original_jit_helper_identity_checks(self):
        for name in sorted(JIT_HELPERS):
            prefix = APP + 'PlugIns/' + name + '/'
            contract = JIT_CONTRACTS[name]
            changes = [
                (lambda info: info.update(CFBundleIdentifier='other'), 'bundle identifier'),
                (lambda info: info['NSExtension'].update(NSExtensionPrincipalClass='Other'), 'principal class'),
                (lambda info: info.update({contract['marker']: '0'}), 'identity marker'),
            ]
            for change, reason in changes:
                with self.subTest(extension=name, reason=reason):
                    members = complete_ipa_members()
                    self.modify_info(members, prefix, change)
                    self.reject(members, reason)

    def test_rejects_wrong_donor_identity_version_or_build(self):
        changes = [
            (lambda info: info.update(CFBundleIdentifier='other.neoswapdonor'), 'bundle identifier'),
            (lambda info: info.update(CFBundlePackageType='APPL'), 'package type'),
            (lambda info: info.update(CFBundleVersion='367'), 'build numbers'),
            (lambda info: info.update(CFBundleShortVersionString='1.0.0'), 'marketing versions'),
            (lambda info: info['NSExtension'].update(NSExtensionPrincipalClass='Other'), 'principal class'),
            (lambda info: info.update(NeoStationNeoSwapDonor='0'), 'identity marker'),
            (lambda info: info.update(MinimumOSVersion='16.0'), 'minimum iOS version'),
            (lambda info: info['NSExtension']['NSExtensionAttributes'].update(
                NSExtensionActivationRule='TRUEPREDICATE'), 'activation rule'),
        ]
        for name in DONOR_IDENTITIES:
            prefix = APP + 'PlugIns/' + name + '/'
            for change, reason in changes:
                with self.subTest(donor=name, reason=reason):
                    members = complete_ipa_members()
                    self.modify_info(members, prefix, change)
                    self.reject(members, reason)

    def test_requires_exact_string_donor_index(self):
        for name, (_, index) in DONOR_IDENTITIES.items():
            for value in (None, int(index), True, '', '-1', '8', str((int(index) + 1) % 8),
                          '$(NEOSWAP_DONOR_INDEX)'):
                with self.subTest(donor=name, index=value):
                    members = complete_ipa_members()
                    def change(info):
                        if value is None:
                            info.pop('NeoStationNeoSwapDonorIndex')
                        else:
                            info['NeoStationNeoSwapDonorIndex'] = value
                    self.modify_info(members, APP + 'PlugIns/' + name + '/', change)
                    self.reject(members, 'donor index')

    def test_requires_exact_donor_context_classes(self):
        for key in ('NSExtensionContextClass', 'NSExtensionContextHostClass'):
            for value in (None, '', 'OtherContext', '$(CONTEXT_CLASS)', 1):
                with self.subTest(key=key, value=value):
                    members = complete_ipa_members()
                    def change(info):
                        if value is None:
                            info['NSExtension'].pop(key)
                        else:
                            info['NSExtension'][key] = value
                    self.modify_info(members, DONOR, change)
                    self.reject(members, key)

    def test_requires_exact_top_level_xpc_service_metadata(self):
        values = [None, [], {}, {'_MultipleInstances': True}]
        for key in DONOR_SERVICE:
            value = dict(DONOR_SERVICE)
            value.pop(key)
            values.append(value)
        for multiple in (False, 1, 'true'):
            values.append(dict(DONOR_SERVICE, _MultipleInstances=multiple))
        values += [dict(DONOR_SERVICE, ServiceType='XPC'),
                   dict(DONOR_SERVICE, _ProcessType='Background'),
                   dict(DONOR_SERVICE, UnexpectedCapability=True)]
        for value in values:
            with self.subTest(value=value):
                members = complete_ipa_members()
                def change(info):
                    if value is None:
                        info.pop('XPCService')
                    else:
                        info['XPCService'] = value
                self.modify_info(members, DONOR, change)
                self.reject(members, 'multiple-instance metadata')

    def test_rejects_misplaced_multiple_instance_metadata(self):
        members = complete_ipa_members()
        def misplaced(info):
            info.pop('XPCService')
            info['NSExtension']['NSExtensionAttributes'].update(_MultipleInstances=True)
        self.modify_info(members, DONOR, misplaced)
        self.reject(members, 'multiple-instance metadata')
        members = complete_ipa_members()
        self.modify_info(members, DONOR, lambda info:
                         info['NSExtension']['NSExtensionAttributes'].update(_MultipleInstances=True))
        self.reject(members, 'activation rule')

    def test_rejects_retired_share_point_and_invalid_donor_extension_metadata(self):
        members = complete_ipa_members()
        self.modify_info(members, DONOR, lambda info:
                         info['NSExtension'].update(NSExtensionPointIdentifier='com.apple.share-services'))
        self.reject(members, 'unexpected extension point')
        members = complete_ipa_members()
        self.modify_info(members, DONOR, lambda info: info.update(NSExtension=[]))
        self.reject(members, 'extension metadata')

    def test_rejects_foreign_or_traversing_donor_executable_name(self):
        for name in DONOR_IDENTITIES:
            executable = name.removesuffix('.appex')
            for value in ('Runner', '../../Runner', '/Runner', 'Other',
                          '../NeoSwapDonor.appex/NeoSwapDonor', './' + executable,
                          '$(EXECUTABLE_NAME)', '', 42):
                with self.subTest(donor=name, executable=value):
                    members = complete_ipa_members()
                    self.modify_info(members, APP + 'PlugIns/' + name + '/',
                                     lambda info: info.update(CFBundleExecutable=value))
                    self.reject(members, 'executable name')

    def test_rejects_missing_or_mistyped_embedded_donor_entitlements(self):
        for name in DONOR_IDENTITIES:
            for key in DONOR_ENTITLEMENTS:
                for value in (None, False, 1, 'true'):
                    with self.subTest(donor=name, entitlement=key, value=value):
                        entitlements = dict(DONOR_ENTITLEMENTS)
                        if value is None:
                            del entitlements[key]
                        else:
                            entitlements[key] = value
                        members = complete_ipa_members()
                        members[APP + 'PlugIns/' + name + '/' + name.removesuffix('.appex')] = macho(entitlements)
                        self.reject(members, 'executable is missing entitlements')

    def test_sidecar_and_profile_cannot_replace_embedded_donor_entitlements(self):
        for name in DONOR_IDENTITIES:
            with self.subTest(donor=name):
                members = complete_ipa_members()
                prefix = APP + 'PlugIns/' + name + '/'
                members[prefix + name.removesuffix('.appex')] = macho(None)
                members[prefix + 'NeoSwapDonor.entitlements'] = plistlib.dumps(DONOR_ENTITLEMENTS)
                members[prefix + 'embedded.mobileprovision'] = plistlib.dumps({
                    'Entitlements': DONOR_ENTITLEMENTS,
                })
                self.reject(members, 'executable is missing entitlements')

    def test_rejects_unexpected_donor_entitlements(self):
        for name in DONOR_IDENTITIES:
            for key in ('com.apple.private.memory.ownership_transfer',
                    'com.apple.developer.memory.transfer-send',
                    'com.apple.developer.memory.transfer-accept',
                    'com.apple.security.application-groups',
                    'unexpected-capability'):
                with self.subTest(donor=name, entitlement=key):
                    members = complete_ipa_members()
                    entitlements = dict(DONOR_ENTITLEMENTS, **{key: True})
                    members[APP + 'PlugIns/' + name + '/' + name.removesuffix('.appex')] = macho(entitlements)
                    self.reject(members, 'unexpected embedded entitlements')

    def test_rejects_non_macho_donor_executable(self):
        for name in DONOR_IDENTITIES:
            with self.subTest(donor=name):
                members = complete_ipa_members()
                members[APP + 'PlugIns/' + name + '/' + name.removesuffix('.appex')] = b'not-a-mach-o'
                self.reject(members, 'Expected a Mach-O executable')

    def test_accepts_arm64_executable_in_fat32_and_fat64(self):
        for wide in (False, True):
            with self.subTest(wide=wide):
                members = complete_ipa_members()
                members[DONOR + 'NeoSwapDonor'] = fat_macho([
                    (0x01000007, macho({}, cpu=0x01000007)),
                    (0x0100000C, macho(DONOR_ENTITLEMENTS)),
                ], wide=wide)
                report = self.validate_members(members)
                self.assertEqual(report['neoSwapDonorCount'], 1)

    def test_rejects_wrong_donor_cpu_or_macho_filetype(self):
        images = [
            (macho(DONOR_ENTITLEMENTS, cpu=0x01000007), 'not arm64'),
            (macho(DONOR_ENTITLEMENTS, filetype=6), 'not MH_EXECUTE'),
            (fat_macho([(0x0100000C, macho(DONOR_ENTITLEMENTS, cpu=0x01000007))]), 'not arm64'),
            (fat_macho([(0x0100000C, macho(DONOR_ENTITLEMENTS, filetype=6))]), 'not MH_EXECUTE'),
        ]
        for name in DONOR_IDENTITIES:
            for data, reason in images:
                with self.subTest(donor=name, reason=reason):
                    members = complete_ipa_members()
                    members[APP + 'PlugIns/' + name + '/' + name.removesuffix('.appex')] = data
                    self.reject(members, reason)

    def test_arm64_gate_rejects_invalid_or_ambiguous_fat_tables(self):
        valid = fat_macho([(0x0100000C, macho(None))])
        bad_range = bytearray(valid)
        struct.pack_into('>I', bad_range, 16, 0)
        images = [
            b'\xca\xfe\xba\xbe',
            struct.pack('>II', 0xCAFEBABE, 0),
            struct.pack('>II', 0xCAFEBABE, 33),
            valid[:-1], bytes(bad_range),
            fat_macho([(0x01000007, macho(None, cpu=0x01000007))]),
            fat_macho([(0x0100000C, macho(None)), (0x0100000C, macho(None))]),
        ]
        for data in images:
            with self.subTest(data=data[:32]):
                with self.assertRaises(validator.DistributionError):
                    validator.require_arm64_executable(data, 'test donor')

    def test_rejects_vpn_extension_point_and_entitlements(self):
        for name in DONOR_IDENTITIES:
            with self.subTest(donor=name):
                members = complete_ipa_members()
                self.modify_info(members, APP + 'PlugIns/' + name + '/',
                                 lambda info: info['NSExtension'].update(
                                     NSExtensionPointIdentifier=validator.PACKET_TUNNEL_EXTENSION_POINT))
                self.reject(members, 'unexpected extension point')
        for key in validator.FORBIDDEN_NETWORK_ENTITLEMENTS:
            donor_paths = {APP + 'PlugIns/' + name + '/' + name.removesuffix('.appex')
                           for name in DONOR_IDENTITIES}
            for path in (APP + 'Runner', *sorted(donor_paths),
                         APP + 'PlugIns/RPCS3JITHelper.appex/RPCS3JITHelper',
                         APP + 'Frameworks/Hidden.framework/Hidden'):
                with self.subTest(entitlement=key, path=path):
                    members = complete_ipa_members()
                    base = REQUIRED_RUNTIME_ENTITLEMENTS if path == APP + 'Runner' else (
                        DONOR_ENTITLEMENTS if path in donor_paths else {})
                    members[path] = macho(dict(base, **{key: True}))
                    self.reject(members, 'retired VPN entitlements')


if __name__ == '__main__':
    unittest.main()
