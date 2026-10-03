#!/usr/bin/env python3
"""Reject an Apple host check that did not execute its UIKit lifecycle probe.

The workflow invokes this separately after Bash returns, so a shell parser
error that incorrectly exits zero cannot masquerade as a simulator pass.
This verifies controlled host behavior only, never real RetroArch gameplay.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


def verify(directory: Path, source_sha: str, *, require_completion: bool = False,
           write_completion: bool = False) -> dict:
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Expected the complete current checkout commit SHA')
    if (directory / 'host-checks-failed.json').exists():
        raise ValueError('The Apple host script recorded a terminal error')
    if (directory / 'source.txt').read_text().strip() != source_sha:
        raise ValueError('Apple host evidence belongs to a different checkout')
    selection = json.loads((directory / 'selected-device.json').read_text())
    if (not isinstance(selection.get('name'), str) or
            not selection['name'].startswith('iPhone') or
            not str(selection.get('runtime', '')).startswith('com.apple.CoreSimulator.SimRuntime.iOS-') or
            not str(selection.get('deviceType', '')).startswith('com.apple.CoreSimulator.SimDeviceType.iPhone-')):
        raise ValueError('No selected compatible iPhone/iOS simulator is recorded')
    report_bytes = (directory / 'host-probe.json').read_bytes()
    report = json.loads(report_bytes)
    expectations = {
        'sourceSHA': source_sha, 'success': True,
        'testRuntimeOnly': True, 'realRetroArchGameplayValidated': False,
        'cycles': 10, 'starts': 12, 'stops': 12, 'endedEvents': 12,
        'firstFrameTimeoutRetainedOwnership': True,
        'lateCallbackIgnored': True, 'stopAcknowledgementRequired': True,
    }
    for key, expected in expectations.items():
        actual = report.get(key)
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f'Lifecycle probe did not prove {key}: {actual!r}')
    completion = {
        'success': True, 'sourceSHA': source_sha, 'exitStatus': 0,
        'verifiedChecks': list(expectations), 'verifiedCheckCount': len(expectations),
        'hostProbeSHA256': hashlib.sha256(report_bytes).hexdigest(),
        'testRuntimeOnly': True, 'realRetroArchGameplayValidated': False,
    }
    if require_completion:
        recorded = json.loads((directory / 'host-checks-complete.json').read_text())
        if recorded != completion:
            raise ValueError('The Apple host script did not complete verification for this exact report')
    if write_completion:
        (directory / 'host-checks-complete.json').write_text(json.dumps(completion, indent=2) + '\n')
    return completion


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('source_sha')
    parser.add_argument('--require-completion', action='store_true')
    parser.add_argument('--write-completion', action='store_true')
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.directory, arguments.source_sha,
                           require_completion=arguments.require_completion,
                           write_completion=arguments.write_completion), indent=2))


if __name__ == '__main__':
    main()
