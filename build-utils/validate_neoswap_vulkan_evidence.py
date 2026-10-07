#!/usr/bin/env python3
"""Validate measured RAM ownership, real Vulkan consumption and GPU retirement."""
import argparse
import json
from pathlib import Path

MIB = 1024**2

def demand(condition, message):
    if not condition:
        raise ValueError(message)

def number(record, key):
    value = record.get(key)
    demand(type(value) is int and value >= 0, f'Invalid measured counter: {key}')
    return value

def validate(report, expected_bytes):
    demand(type(expected_bytes) is int and 128*MIB <= expected_bytes <= 8192*MIB,
           'Invalid requested native proof size')
    demand(isinstance(report, dict), 'Native report must be an object')
    demand(report.get('passed') is True and report.get('residentTargetVerified') is True,
           'Native residency proof did not pass')
    demand(report.get('platform') == 'macOS-NSXPC-two-process' and report.get('schema') == 2,
           'Unexpected native proof platform or schema')
    demand(report.get('residentMeasurementPhase') == 'vulkan_live_buffers_after_gpu_completion',
           'The resident target must be measured while Vulkan actually uses donor pages')
    host, donor = number(report, 'hostPID'), number(report, 'donorPID')
    demand(host > 0 and donor > 0 and host != donor, 'Donor must have its own real PID')
    for key in ('targetBytes', 'requestedBytes', 'preparedBytes', 'capacityBytes'):
        demand(number(report, key) == expected_bytes, f'Incomplete native target: {key}')
    demand(expected_bytes-MIB <= number(report, 'donorResidentBytes') <= expected_bytes,
           'Prepared donor pages are not resident at the requested target')
    demand(number(report, 'donorCompressedBytes') <= MIB,
           'Compressed pages cannot substitute for the resident target')
    demand(report.get('iphoneExtensionValidated') is False,
           'A Mac proof cannot claim validation of iPhone extensions')
    gpu = report.get('vulkanDonation')
    demand(isinstance(gpu, dict), 'Vulkan measurements are absent')
    for key in ('passed', 'gpuToCpuAliasVerified', 'productionRPCS3ImportPath',
                'productionHostBroker', 'donorLedgerRefreshedAfterGPU'):
        demand(gpu.get(key) is True, f'Incomplete Vulkan proof: {key}')
    for key in ('realIPhoneValidated', 'realRPCS3GameplayValidated', 'fileArenaConfigured'):
        demand(gpu.get(key) is False, f'Unsupported native claim: {key}')
    for key in ('importedBytes', 'donatedLiveBytesDuringGPU', 'gpuWrittenBytes', 'rendererBudgetDuringGPU'):
        demand(number(gpu, key) == expected_bytes, f'Vulkan did not consume the target: {key}')
    for key in ('retiredLiveBytes', 'rendererBudgetAfterRetirement', 'allocatedDiskBytesDuringGPU',
                'retiredPoolLiveBytes', 'retiredPoolLiveBlocks', 'retiredHostLiveBytes',
                'retiredDonatedLiveBytes', 'retirementPendingLoans'):
        demand(number(gpu, key) == 0, f'Unexpected retained or file-backed memory: {key}')
    demand(expected_bytes-MIB <= number(gpu, 'donorResidentAfterGPUBytes') <= expected_bytes,
           'Donor residency fell below the target while the Vulkan loans were alive')
    demand(number(gpu, 'donorCompressedAfterGPUBytes') <= MIB,
           'Post-GPU compressed pages cannot substitute for resident RAM')
    count = number(gpu, 'bufferCount')
    demand(count == number(report, 'verifiedChunkCount') and
           count >= (expected_bytes + 256*MIB-1)//(256*MIB),
           'Vulkan did not import the independently verified bounded chunks')
    demand(number(gpu, 'retirementQueuedLoans') == count and
           number(gpu, 'retirementCompletedLoans') == count and
           number(gpu, 'retirementQueuedBytes') == expected_bytes,
           'FAST retirement must observe every queued loan and its retained bytes before draining')
    limit = number(gpu, 'retirementMaintenanceLimit')
    demand(limit == (count + 31)//32 + 4 and count <= 1024 and
           1 <= number(gpu, 'retirementMaintenancePasses') <= limit,
           'Retirement exceeded its bounded maintenance budget or was not exercised')
    demand(number(gpu, 'retirementElapsedUs') <= 2_000_000,
           'Retirement exceeded the native proof deadline')
    number(gpu, 'retirementFailureCount')  # Retries may succeed; retained loans may never be hidden.
    demand(number(gpu, 'hostNonvolatileDeltaBytes') < MIB and
           number(gpu, 'hostFootprintDeltaBytes') < 64*MIB,
           'Substantial imported memory was charged to the host')
    return {'passed': True, 'targetBytes': expected_bytes, 'bufferCount': count,
            'donorResidentAfterGPUBytes': gpu['donorResidentAfterGPUBytes'],
            'hostFootprintDeltaBytes': gpu['hostFootprintDeltaBytes'],
            'retirementMaintenancePasses': gpu['retirementMaintenancePasses'],
            'retirementElapsedUs': gpu['retirementElapsedUs'],
            'retirementFailureCount': gpu['retirementFailureCount'],
            'realIPhoneValidated': False, 'realRPCS3GameplayValidated': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--bytes', type=int, required=True)
    args = parser.parse_args()
    print(json.dumps(validate(json.loads(args.report.read_text()), args.bytes), indent=2))
