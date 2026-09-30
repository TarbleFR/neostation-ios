"""Negative evidence cases: synthetic fixtures test the validator, not native RAM."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('vulkan_evidence', ROOT/'build-utils/validate_neoswap_vulkan_evidence.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TARGET = 1024**3
REPORT = {
    'schema': 2, 'platform': 'macOS-NSXPC-two-process', 'passed': True,
    'residentTargetVerified': True, 'hostPID': 10, 'donorPID': 11,
    'targetBytes': TARGET, 'requestedBytes': TARGET, 'preparedBytes': TARGET,
    'capacityBytes': TARGET, 'donorResidentBytes': TARGET, 'donorCompressedBytes': 0,
    'verifiedChunkCount': 5, 'iphoneExtensionValidated': False,
    'vulkanDonation': {
        'passed': True, 'gpuToCpuAliasVerified': True, 'productionRPCS3ImportPath': True,
        'productionHostBroker': True, 'donorLedgerRefreshedAfterGPU': True,
        'realIPhoneValidated': False, 'realRPCS3GameplayValidated': False,
        'fileArenaConfigured': False, 'allocatedDiskBytesDuringGPU': 0,
        'importedBytes': TARGET, 'donatedLiveBytesDuringGPU': TARGET,
        'gpuWrittenBytes': TARGET, 'rendererBudgetDuringGPU': TARGET,
        'retiredLiveBytes': 0, 'rendererBudgetAfterRetirement': 0,
        'donorResidentAfterGPUBytes': TARGET, 'donorCompressedAfterGPUBytes': 0,
        'bufferCount': 5, 'hostNonvolatileDeltaBytes': 0, 'hostFootprintDeltaBytes': 2*1024**2,
    },
}

class EvidenceTests(unittest.TestCase):
    def test_full_measured_target(self):
        self.assertTrue(module.validate(copy.deepcopy(REPORT), TARGET)['passed'])

    def test_reject_incomplete_or_misleading_measurements(self):
        cases = [
            (None, 'passed', False), (None, 'hostPID', 11),
            (None, 'preparedBytes', TARGET//8), (None, 'donorResidentBytes', TARGET//2),
            (None, 'donorCompressedBytes', TARGET//2), (None, 'iphoneExtensionValidated', True),
            ('gpu', 'importedBytes', TARGET//8), ('gpu', 'donatedLiveBytesDuringGPU', 0),
            ('gpu', 'gpuWrittenBytes', 0), ('gpu', 'gpuToCpuAliasVerified', False),
            ('gpu', 'retiredLiveBytes', 4096), ('gpu', 'rendererBudgetDuringGPU', 0),
            ('gpu', 'rendererBudgetAfterRetirement', 4096), ('gpu', 'bufferCount', 1),
            ('gpu', 'donorLedgerRefreshedAfterGPU', False),
            ('gpu', 'donorResidentAfterGPUBytes', TARGET//2),
            ('gpu', 'donorCompressedAfterGPUBytes', TARGET//2),
            ('gpu', 'fileArenaConfigured', True), ('gpu', 'allocatedDiskBytesDuringGPU', 4096),
            ('gpu', 'hostNonvolatileDeltaBytes', 1024**2),
            ('gpu', 'hostFootprintDeltaBytes', 64*1024**2),
            ('gpu', 'realIPhoneValidated', True), ('gpu', 'realRPCS3GameplayValidated', True),
            ('gpu', 'importedBytes', True), ('gpu', 'productionHostBroker', False),
        ]
        for section, key, value in cases:
            with self.subTest(key=key, value=value):
                report = copy.deepcopy(REPORT)
                (report['vulkanDonation'] if section else report)[key] = value
                with self.assertRaises(ValueError):
                    module.validate(report, TARGET)

    def test_128mib_compatibility(self):
        report = copy.deepcopy(REPORT)
        target = 128*1024**2
        for key in ('targetBytes', 'requestedBytes', 'preparedBytes', 'capacityBytes', 'donorResidentBytes'):
            report[key] = target
        report['verifiedChunkCount'] = 2
        for key in ('importedBytes', 'donatedLiveBytesDuringGPU', 'gpuWrittenBytes',
                    'rendererBudgetDuringGPU', 'donorResidentAfterGPUBytes'):
            report['vulkanDonation'][key] = target
        report['vulkanDonation']['bufferCount'] = 2
        self.assertTrue(module.validate(report, target)['passed'])

if __name__ == '__main__':
    unittest.main()
