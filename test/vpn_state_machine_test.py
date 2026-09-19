from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swiftc = shutil.which('swiftc')
if not swiftc:
    raise SystemExit('Swift compiler required: this gate must run on the macOS CI runner')
with tempfile.TemporaryDirectory(prefix='neostation-vpn-test-') as temp:
    binary = str(Path(temp) / 'vpn-test')
    subprocess.run([swiftc, '-D', 'NEOSTATION_TUNNEL_TESTING',
        str(root / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'),
        str(root / 'test/native/tunnel_manager_stubs.swift'),
        str(root / 'test/native/tunnel_manager_main.swift'), '-o', binary], check=True)
    for case in ['on-off-late-save', 'timeout-retry', 'fail-fast', 'duplicate-on', 'connected-no-save', 'readonly-route']:
        subprocess.run([binary, case], check=True, timeout=5)
