"""Exercise the actual workflow evidence producer/copy across Flutter build cleanup."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / '.github/workflows/neoswap-ipa.yml').read_text()
gate = workflow.split('- name: Require exact import, 8GiB memory and retained simulator checks before compilation', 1)[1].split('\n      - name:', 1)[0]
script = textwrap.dedent(re.search(r"python3 - <<'PY'\n(.*?)\n          PY", gate, re.S).group(1))
copy_command = next(line.strip() for line in workflow.splitlines() if line.strip().startswith('cp ') and 'capacity-8GiB-macOS.json' in line)
sha = 'd' * 40
report = {'platform': 'macOS host', 'verifiedBytes': 8589934592,
          'footprintBefore': 1049280, 'footprintPeak': 5325504,
          'realIPhoneValidated': False}

def api(command):
    assert command[:2] == ['gh', 'api']
    assert 'head_sha=' + sha in command[2]
    return json.dumps({'workflow_runs': [{'head_sha': sha, 'status': 'completed',
                                       'conclusion': 'success', 'id': 1}]}).encode()

def run(command, *, check):
    assert check is True
    if command[:3] == ['gh', 'run', 'download']:
        assert command[command.index('-n') + 1] == 'NeoSwap-checks-' + sha
        destination = Path(command[command.index('-D') + 1])
        destination.mkdir(parents=True, exist_ok=True)
        (destination / 'capacity-8GiB-macOS.txt').write_text(json.dumps(report) + '\n')
    else:
        assert command in (['python3', 'test/stikjit_scoped_host_test.py'],
                           ['python3', 'test/dolphin_phone_shake_test.py'])
    return subprocess.CompletedProcess(command, 0)

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    checkout = base / 'checkout'
    checkout.mkdir()
    runner_temp = base / 'runner-temp'
    runner_temp.mkdir()
    environment = dict(os.environ, GITHUB_SHA=sha, RUNNER_TEMP=str(runner_temp))
    previous = Path.cwd()
    try:
        os.chdir(checkout)
        with patch.dict(os.environ, environment), patch.object(subprocess, 'check_output', api), patch.object(subprocess, 'run', run):
            exec(compile(script, '.github/workflows/neoswap-ipa.yml', 'exec'), {})
        # flutter clean removes the checkout's build directory after the gate.
        (checkout / 'build').mkdir(exist_ok=True)
        shutil.rmtree(checkout / 'build')
        (checkout / 'build/private-test').mkdir(parents=True)
        subprocess.run(['bash', '-c', copy_command], check=True, env=environment)
        assert json.loads((checkout / 'build/private-test/capacity-8GiB-macOS.json').read_text()) == report
    finally:
        os.chdir(previous)

print('PASS: actual exact-SHA 8GiB evidence producer/export survives Flutter build cleanup')
