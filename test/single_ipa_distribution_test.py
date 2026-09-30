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
JIT_HELPERS = {
    'DolphinJITHelper.appex', 'RPCS3JITHelper.appex', 'ARMSX2JITHelper.appex',
}


def macho(entitlements: dict | None) -> bytes:
    if entitlements is None:
        return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
    xml = plistlib.dumps(entitlements)
    slot = struct.pack('>II', 0xFADE7171, len(xml) + 8) + xml
    signature = struct.pack('>III', 0xFADE0CC0, len(slot) + 20, 1)
    signature += struct.pack('>II', 5, 20) + slot
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack('<4I', 0x1D, 16, 48, len(signature)) + signature


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
    for name, contract in validator.EXPECTED_EXTENSIONS.items():
        executable = name.removesuffix('.appex')
        info = {
            'CFBundleExecutable': executable,
            'CFBundleIdentifier': host['CFBundleIdentifier'] + contract['bundleSuffix'],
            'CFBundlePackageType': 'XPC!',
            'CFBundleVersion': host['CFBundleVersion'],
            'CFBundleShortVersionString': host['CFBundleShortVersionString'],
            contract['marker']: '1',
            'NSExtension': {
                'NSExtensionPointIdentifier': validator.SHARE_EXTENSION_POINT,
                'NSExtensionPrincipalClass': contract['principalClass'],
            },
        }
        prefix = APP + 'PlugIns/' + name + '/'
        members[prefix + 'Info.plist'] = plistlib.dumps(info)
        entitlements = validator.REQUIRED_DONOR_ENTITLEMENTS if name == 'NeoSwapDonor.appex' else None
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

    def test_accepts_one_app_with_exact_original_helpers_and_donor(self):
        self.assertEqual(set(validator.EXPECTED_EXTENSIONS), JIT_HELPERS | {'NeoSwapDonor.appex'})
        report = self.validate_members(complete_ipa_members())
        self.assertEqual(report['installationUnits'], 1)
        self.assertEqual({entry['bundle'] for entry in report['embeddedExtensions']},
                         JIT_HELPERS | {'NeoSwapDonor.appex'})
        self.assertEqual(report['neoSwapDonorRequestedEntitlements'],
                         validator.REQUIRED_DONOR_ENTITLEMENTS)
        self.assertIs(report['neoSwapDonorEffectiveDeviceProfileValidated'], False)
        self.assertIs(report['deviceRuntimeTested'], False)
        self.assertEqual(len(report['nestedSigningOrder']), 5)
        self.assertEqual(report['nestedSigningOrder'][-1], 'NeoStation.app')

    def test_requires_each_of_the_four_extensions(self):
        for name in validator.EXPECTED_EXTENSIONS:
            with self.subTest(extension=name):
                prefix = APP + 'PlugIns/' + name + '/'
                members = {path: data for path, data in complete_ipa_members().items()
                           if not path.startswith(prefix)}
                self.reject(members, 'Unexpected app-extension set')

    def test_rejects_unexpected_extension(self):
        members = complete_ipa_members()
        members[APP + 'PlugIns/Other.appex/Info.plist'] = plistlib.dumps({})
        self.reject(members, 'Unexpected app-extension set')

    def test_rejects_second_installable_app(self):
        members = complete_ipa_members()
        members['Payload/Other.app/Info.plist'] = plistlib.dumps({})
        self.reject(members, 'exactly one installable app')

    def test_rejects_donor_outside_host_plugins(self):
        members = {path.replace(DONOR, 'NeoSwapDonor.appex/'): data
                   for path, data in complete_ipa_members().items()}
        self.reject(members, 'Every app extension must remain nested')

    def test_preserves_original_jit_helper_identity_checks(self):
        for name in sorted(JIT_HELPERS):
            prefix = APP + 'PlugIns/' + name + '/'
            contract = validator.EXPECTED_EXTENSIONS[name]
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
        ]
        for change, reason in changes:
            with self.subTest(reason=reason):
                members = complete_ipa_members()
                self.modify_info(members, DONOR, change)
                self.reject(members, reason)

    def test_rejects_missing_or_mistyped_embedded_donor_entitlements(self):
        for key in validator.REQUIRED_DONOR_ENTITLEMENTS:
            for value in (None, False, 1, 'true'):
                with self.subTest(entitlement=key, value=value):
                    entitlements = dict(validator.REQUIRED_DONOR_ENTITLEMENTS)
                    if value is None:
                        del entitlements[key]
                    else:
                        entitlements[key] = value
                    members = complete_ipa_members()
                    members[DONOR + 'NeoSwapDonor'] = macho(entitlements)
                    self.reject(members, 'NeoSwapDonor executable is missing entitlements')

    def test_sidecar_and_profile_cannot_replace_embedded_donor_entitlements(self):
        members = complete_ipa_members()
        members[DONOR + 'NeoSwapDonor'] = macho(None)
        members[DONOR + 'NeoSwapDonor.entitlements'] = plistlib.dumps(validator.REQUIRED_DONOR_ENTITLEMENTS)
        members[DONOR + 'embedded.mobileprovision'] = plistlib.dumps({
            'Entitlements': validator.REQUIRED_DONOR_ENTITLEMENTS,
        })
        self.reject(members, 'NeoSwapDonor executable is missing entitlements')

    def test_rejects_unexpected_donor_entitlements(self):
        for key in ('com.apple.private.memory.ownership_transfer',
                    'com.apple.developer.memory.transfer-send',
                    'com.apple.developer.memory.transfer-accept',
                    'com.apple.security.application-groups',
                    'unexpected-capability'):
            with self.subTest(entitlement=key):
                members = complete_ipa_members()
                entitlements = dict(validator.REQUIRED_DONOR_ENTITLEMENTS, **{key: True})
                members[DONOR + 'NeoSwapDonor'] = macho(entitlements)
                self.reject(members, 'unexpected embedded entitlements')

    def test_rejects_non_macho_donor_executable(self):
        members = complete_ipa_members()
        members[DONOR + 'NeoSwapDonor'] = b'not-a-mach-o'
        self.reject(members, 'Expected a Mach-O executable')

    def test_rejects_vpn_extension_point_and_entitlements(self):
        members = complete_ipa_members()
        self.modify_info(members, DONOR, lambda info: info['NSExtension'].update(
            NSExtensionPointIdentifier=validator.PACKET_TUNNEL_EXTENSION_POINT))
        self.reject(members, 'unexpected extension point')
        for key in validator.FORBIDDEN_NETWORK_ENTITLEMENTS:
            for path in (APP + 'Runner', DONOR + 'NeoSwapDonor',
                         APP + 'PlugIns/RPCS3JITHelper.appex/RPCS3JITHelper',
                         APP + 'Frameworks/Hidden.framework/Hidden'):
                with self.subTest(entitlement=key, path=path):
                    members = complete_ipa_members()
                    base = REQUIRED_RUNTIME_ENTITLEMENTS if path == APP + 'Runner' else (
                        validator.REQUIRED_DONOR_ENTITLEMENTS if path.startswith(DONOR) else {})
                    members[path] = macho(dict(base, **{key: True}))
                    self.reject(members, 'retired VPN entitlements')


if __name__ == '__main__':
    unittest.main()
