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
    'residentMeasurementPhase': 'vulkan_live_buffers_after_gpu_completion',
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
        'retirementQueuedLoans': 5, 'retirementQueuedBytes': TARGET, 'retirementCompletedLoans': 5,
        'retirementPendingLoans': 0, 'retirementMaintenancePasses': 1, 'retirementMaintenanceLimit': 5,
        'retirementFailureCount': 0, 'retirementElapsedUs': 400,
        'retiredPoolLiveBytes': 0, 'retiredPoolLiveBlocks': 0,
        'retiredHostLiveBytes': 0, 'retiredDonatedLiveBytes': 0,
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
            (None, 'residentMeasurementPhase', 'prepared_donor_before_consumer'),
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
            ('gpu', 'retirementQueuedLoans', 0), ('gpu', 'retirementCompletedLoans', 4),
            ('gpu', 'retirementQueuedBytes', TARGET//2), ('gpu', 'retirementPendingLoans', 1),
            ('gpu', 'retirementMaintenancePasses', 0), ('gpu', 'retirementMaintenancePasses', 6),
            ('gpu', 'retirementMaintenanceLimit', 6), ('gpu', 'retirementElapsedUs', 2_000_001),
            ('gpu', 'retirementFailureCount', True), ('gpu', 'retiredPoolLiveBytes', 4096),
            ('gpu', 'retiredPoolLiveBlocks', 1), ('gpu', 'retiredHostLiveBytes', 4096),
            ('gpu', 'retiredDonatedLiveBytes', 4096),
        ]
        for section, key, value in cases:
            with self.subTest(key=key, value=value):
                report = copy.deepcopy(REPORT)
                (report['vulkanDonation'] if section else report)[key] = value
                with self.assertRaises(ValueError):
                    module.validate(report, TARGET)

    def test_missing_retirement_observations_cannot_pass(self):
        for key in ('retirementQueuedLoans', 'retirementQueuedBytes', 'retirementCompletedLoans',
                    'retirementPendingLoans', 'retirementMaintenancePasses', 'retirementMaintenanceLimit',
                    'retirementFailureCount', 'retirementElapsedUs', 'retiredPoolLiveBytes',
                    'retiredPoolLiveBlocks', 'retiredHostLiveBytes', 'retiredDonatedLiveBytes'):
            with self.subTest(key=key):
                report = copy.deepcopy(REPORT)
                del report['vulkanDonation'][key]
                with self.assertRaises(ValueError):
                    module.validate(report, TARGET)

    def test_measured_transient_failure_can_complete_within_bound(self):
        report = copy.deepcopy(REPORT)
        report['vulkanDonation']['retirementFailureCount'] = 1
        report['vulkanDonation']['retirementMaintenancePasses'] = 2
        self.assertTrue(module.validate(report, TARGET)['passed'])

    def test_128mib_compatibility(self):
        report = copy.deepcopy(REPORT)
        target = 128*1024**2
        for key in ('targetBytes', 'requestedBytes', 'preparedBytes', 'capacityBytes', 'donorResidentBytes'):
            report[key] = target
        report['verifiedChunkCount'] = 2
        for key in ('importedBytes', 'donatedLiveBytesDuringGPU', 'gpuWrittenBytes',
                    'rendererBudgetDuringGPU', 'donorResidentAfterGPUBytes', 'retirementQueuedBytes'):
            report['vulkanDonation'][key] = target
        report['vulkanDonation']['bufferCount'] = 2
        report['vulkanDonation']['retirementQueuedLoans'] = 2
        report['vulkanDonation']['retirementCompletedLoans'] = 2
        self.assertTrue(module.validate(report, target)['passed'])

if __name__ == '__main__':
    unittest.main()
