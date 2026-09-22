#!/usr/bin/env python3
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import sys

ROOT=Path(__file__).resolve().parents[1]
PATCH=ROOT/'build-utils/patch_rpcs3_build303_restartable_lifecycle.py'
spec=spec_from_file_location('restartable', PATCH)
module=module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

upstream='''#pragma once
enum State { RPCS3_IOS_STATE_UNINITIALIZED, RPCS3_IOS_STATE_INITIALIZING, RPCS3_IOS_STATE_STOPPED };
enum Status { RPCS3_IOS_OK, RPCS3_IOS_INVALID_STATE };
class lifecycle {
public:
 Status begin_initialize() noexcept
 {
		if (m_state != RPCS3_IOS_STATE_UNINITIALIZED)
		{
			return RPCS3_IOS_INVALID_STATE;
		}
		m_state = RPCS3_IOS_STATE_INITIALIZING;
		return RPCS3_IOS_OK;
 }
private:
 State m_state = RPCS3_IOS_STATE_UNINITIALIZED;
};
'''
with tempfile.TemporaryDirectory() as temp:
    root=Path(temp)
    path=root/'rpcs3/ios/RPCS3IOSContract.h'
    path.parent.mkdir(parents=True)
    path.write_text(upstream)
    module.patch(root)
    once=path.read_text()
    module.patch(root)
    twice=path.read_text()
    assert once == twice
    assert module.MARKER in once
    assert 'm_state != RPCS3_IOS_STATE_STOPPED' in once
    assert 'm_state != RPCS3_IOS_STATE_UNINITIALIZED &&' in once
if len(sys.argv) > 1:
    actual = (Path(sys.argv[1])/'rpcs3/ios/RPCS3IOSContract.h').read_text()
    assert module.MARKER in actual
    assert 'm_state != RPCS3_IOS_STATE_UNINITIALIZED &&' in actual
    assert 'm_state != RPCS3_IOS_STATE_STOPPED' in actual
print('PASS: Build303 lifecycle permits reinitialize only after a clean STOPPED boundary')
