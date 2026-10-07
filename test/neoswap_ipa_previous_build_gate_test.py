#!/usr/bin/env python3
"""Execute the IPA workflow's previous-build gate against a fake gh CLI.

7 October 2026: GitHub no longer holds the successful Build411 run record
37605768644 (every run before 11:51 UTC was deleted) and retains no other
successful Build411 run. The gate must still refuse an unexpected API
failure, still require success, the exact commit and artifact retention
when the record exists, and on HTTP 404 accept only the documented Build411
identity (run, commit, NeoStation.ipa SHA-256 in docs/neoplay/BUILD411.md at
the packaged commit) when the Build411 commit is an ancestor of the candidate
and no Build411 packaging run is still active.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/neoswap-ipa.yml'
RUN_ID = '37605768644'
COMMIT = '8c63c682946b7ad736d5391086016399100c4bd9'
IPA_SHA256 = 'da40c7a774d4bf3e9766111e5e69b7d1a69ad1b5c3d4d67e0833015944d9c8ec'
PACKAGED_SHA = 'f' * 40
FAKE_GH = """#!/bin/bash
case "$2" in
  *actions/runs/RUN_ID/artifacts*) printf '%s\\n' "$FAKE_ARTIFACTS";;
  *actions/runs/RUN_ID*)
    case "$FAKE_RUN_MODE" in
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1;;
      500) echo "gh: Server Error (HTTP 500)" >&2; exit 1;;
      *) printf '%s\\n' "$FAKE_RUN";;
    esac;;
  *compare/COMMIT...PACKAGED_SHA) printf '%s\\n' "$FAKE_COMPARE";;
  *actions/workflows/neoswap-ipa.yml/runs*) printf '%s\\n' "$FAKE_WORKFLOW_RUNS";;
  *contents/docs/neoplay/BUILD411.md?ref=PACKAGED_SHA) printf '%s\\n' "$FAKE_CONTENTS";;
  *) echo "unexpected gh call: $*" >&2; exit 2;;
esac
""".replace('RUN_ID', RUN_ID).replace('COMMIT', COMMIT).replace('PACKAGED_SHA', PACKAGED_SHA)
RETAINED_RUNS = [
    {'id': 37632022216, 'name': 'NeoStation NeoSwap + NeoPlay private • Build 412 • ' + PACKAGED_SHA, 'status': 'completed'},
    {'id': 37618048149, 'name': 'NeoStation NeoSwap + NeoPlay private • Build 411 • d317c956', 'status': 'completed'},
]


def gate_script() -> str:
    text = WORKFLOW.read_text()
    start = text.index("python3 - <<'PREVIOUS'\n") + len("python3 - <<'PREVIOUS'\n")
    end = text.index('\n          PREVIOUS\n', start)
    lines = text[start:end].splitlines()
    assert all(line.startswith('          ') or not line.strip() for line in lines), lines
    return '\n'.join(line[10:] for line in lines) + '\n'


def run_gate(folder: Path, mode: str, notes: str, run=None, artifacts=None,
             compare='ahead', workflow_runs=RETAINED_RUNS):
    env = dict(os.environ)
    env['PATH'] = str(folder) + os.pathsep + env['PATH']
    env['GITHUB_SHA'] = PACKAGED_SHA
    env['FAKE_RUN_MODE'] = mode
    env['FAKE_RUN'] = json.dumps(run or {})
    env['FAKE_ARTIFACTS'] = json.dumps({'artifacts': artifacts or []})
    env['FAKE_COMPARE'] = json.dumps({'status': compare, 'ahead_by': 32, 'behind_by': 0})
    env['FAKE_WORKFLOW_RUNS'] = json.dumps({'workflow_runs': workflow_runs})
    env['FAKE_CONTENTS'] = json.dumps({'content': base64.b64encode(notes.encode()).decode()})
    return subprocess.run([sys.executable, '-I', '-'], input=gate_script(), capture_output=True,
                          text=True, env=env, cwd=folder, timeout=30)


def main() -> None:
    script = gate_script()
    assert f'run_id = {RUN_ID}' in script and f"expected_sha = '{COMMIT}'" in script
    assert f"ipa_sha256 = '{IPA_SHA256}'" in script
    documented = (ROOT / 'docs/neoplay/BUILD411.md').read_text()
    for token in (RUN_ID, COMMIT, IPA_SHA256):
        assert token in documented, token
    with tempfile.TemporaryDirectory(prefix='ipa-previous-gate-') as temporary:
        folder = Path(temporary)
        fake = folder / 'gh'
        fake.write_text(FAKE_GH)
        fake.chmod(0o755)
        run = {'head_sha': COMMIT, 'path': '.github/workflows/neoswap-ipa.yml', 'status': 'completed',
               'conclusion': 'success', 'updated_at': '2026-10-07T10:46:18Z'}
        # Record present, successful, artifact retained: unchanged acceptance.
        kept = run_gate(folder, 'present', documented, run,
                        [{'name': 'NeoStation-NeoSwap-NeoPlay-Build-411-' + COMMIT, 'expired': False}])
        assert kept.returncode == 0 and 'its IPA artifact is preserved' in kept.stdout, kept
        # Record present but failed: still refused.
        failed = run_gate(folder, 'present', documented, dict(run, conclusion='failure'))
        assert failed.returncode != 0 and 'Build411 did not succeed' in failed.stderr, failed
        # Record present with another commit: refused.
        other = run_gate(folder, 'present', documented, dict(run, head_sha='0' * 40))
        assert other.returncode != 0 and 'AssertionError' in other.stderr, other
        # Record present, artifact absent before retention: refused.
        early = run_gate(folder, 'present', documented, dict(run, updated_at='2099-01-01T00:00:00Z'))
        assert early.returncode != 0 and 'before its 3-day retention elapsed' in early.stderr, early
        # Record deleted (HTTP 404): ancestry, no active Build411 run and the
        # documented identity are required together and sufficient.
        deleted = run_gate(folder, '404', documented)
        assert deleted.returncode == 0, deleted
        assert 'documented identity verified' in deleted.stdout, deleted
        assert RUN_ID in deleted.stdout and COMMIT in deleted.stdout and IPA_SHA256 in deleted.stdout
        # Deleted record, Build411 commit not in this candidate's history: refused.
        for status in ('diverged', 'behind'):
            foreign = run_gate(folder, '404', documented, compare=status)
            assert foreign.returncode != 0 and 'not an ancestor' in foreign.stderr, (status, foreign)
        # Deleted record, a Build411 packaging run still active: refused.
        active = run_gate(folder, '404', documented,
                          workflow_runs=RETAINED_RUNS + [{'id': 1, 'name': 'NeoStation NeoSwap + NeoPlay private • Build 411 • e', 'status': 'in_progress'}])
        assert active.returncode != 0 and 'still active: 1' in active.stderr, active
        # Deleted record and the notes lack any identity token: refused.
        for missing in (IPA_SHA256, COMMIT, RUN_ID):
            incomplete = run_gate(folder, '404', documented.replace(missing, 'x' * len(missing)))
            assert incomplete.returncode != 0 and 'Build411 identity missing' in incomplete.stderr, (missing, incomplete)
        # Any other API failure is still an error, never an acceptance.
        outage = run_gate(folder, '500', documented)
        assert outage.returncode != 0 and 'CalledProcessError' in outage.stderr, outage
        assert 'documented identity verified' not in outage.stdout
    print('PASS: previous-build gate keeps success, commit and retention checks when the Build411 record exists; '
          'a deleted record is accepted only with ancestry, no active Build411 run and the documented run, commit '
          'and IPA SHA-256; other API failures still block')


if __name__ == '__main__':
    main()
