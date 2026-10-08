"""Measure real command wall time without recording secret-bearing arguments."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

label, *command = sys.argv[1:]
start = time.monotonic()
result = subprocess.run(command)
out = Path(os.environ.get('DELIVERY_METRICS', 'build/delivery/timings.jsonl'))
out.parent.mkdir(parents=True, exist_ok=True)
with out.open('a') as handle:
    handle.write(json.dumps({'phase': label, 'seconds': time.monotonic() - start,
                             'exitCode': result.returncode}) + '\n')
raise SystemExit(result.returncode)
