#!/usr/bin/env python3
"""CLI compatibility shim for the deferred RPCS3 iOS JIT patch."""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from deferred_jit import (  # noqa: E402
    MARKER, PatchError, Initializer, _initializer_at, _all_initializers,
    _wrap_initializer, replace_once, patch, validate_source_tree,
)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: deferred_jit_init.py <pinned-rpcs3-source>")
    patch(Path(sys.argv[1]))
