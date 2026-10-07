#!/usr/bin/env python3
"""Exercise the KartPad donor restoration from a packaged IPA."""
from __future__ import annotations

import hashlib
import io
import json
import runpy
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
restore = runpy.run_path(str(ROOT / "build-utils/restore_kartpad_donor_from_ipa.py"))["restore"]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_ipa(path: Path, *, core: bytes, runtime: bytes, resources: dict[str, bytes],
              identity_overrides: dict | None = None, packaged_core: bytes | None = None,
              packaged_resources: dict[str, bytes] | None = None) -> str:
    identity = {
        "host_commit": "1" * 40, "mode": "official-ipa-donor",
        "sha256": sha(core), "runtime_sha256": sha(runtime),
        "runtime_resources": {name: sha(data) for name, data in resources.items()},
    }
    identity.update(identity_overrides or {})
    app = "Payload/NeoStation.app/"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        executable = zipfile.ZipInfo(app + "Frameworks/KartPadCore.framework/KartPadCore")
        executable.external_attr = 0o100755 << 16
        archive.writestr(executable, packaged_core if packaged_core is not None else core)
        archive.writestr(app + "Frameworks/KartPadCore.framework/Info.plist", b"core-plist")
        archive.writestr(app + "Frameworks/KartPadRuntime.framework/KartPadRuntime", runtime)
        archive.writestr(app + "Frameworks/KartPadRuntime.framework/Info.plist", b"runtime-plist")
        archive.writestr(app + "Frameworks/Other.framework/Other", b"unrelated")
        for name, data in (packaged_resources or resources).items():
            archive.writestr(app + name, data)
        archive.writestr(app + "KartPad-native-identity.json", json.dumps(identity))
    path.write_bytes(buffer.getvalue())
    return sha(buffer.getvalue())


def run(ipa: Path, output: Path, ipa_sha: str, core: bytes, runtime: bytes) -> dict:
    return restore(ipa, output, ipa_sha256=ipa_sha, host_commit="1" * 40,
                   core_sha256=sha(core), runtime_sha256=sha(runtime))


def expect_refusal(label: str, action) -> None:
    try:
        action()
    except SystemExit as error:
        print(f"refused {label}: {error}")
        return
    raise AssertionError(f"{label} was accepted")


def main() -> None:
    core, runtime = b"core-binary", b"runtime-binary"
    resources = {"dsp_coef.bin": b"dsp", "wii_bootstrap/shared2/wc24/misc.bin": b"misc"}
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        ipa = temp / "good.ipa"
        good_sha = build_ipa(ipa, core=core, runtime=runtime, resources=resources)
        output = temp / "donor"
        report = run(ipa, output, good_sha, core, runtime)
        assert report["frameworkFiles"] == 4 and report["runtimeResources"] == 2, report
        assert (output / "KartPadCore.framework/KartPadCore").read_bytes() == core
        assert (output / "KartPadRuntime.framework/KartPadRuntime").read_bytes() == runtime
        assert (output / "KartPadCore.framework/Info.plist").read_bytes() == b"core-plist"
        assert (output / "runtime-resources/wii_bootstrap/shared2/wc24/misc.bin").read_bytes() == b"misc"
        assert not (output / "Other.framework").exists()
        assert json.loads((output / "identity.json").read_text())["host_commit"] == "1" * 40

        expect_refusal("different source IPA",
                       lambda: run(ipa, temp / "o1", "0" * 64, core, runtime))
        expect_refusal("non-empty output", lambda: run(ipa, output, good_sha, core, runtime))

        tampered = temp / "tampered-core.ipa"
        tampered_sha = build_ipa(tampered, core=core, runtime=runtime, resources=resources,
                                 packaged_core=b"other-core")
        expect_refusal("Core bytes differing from identity",
                       lambda: run(tampered, temp / "o2", tampered_sha, core, runtime))

        stale = temp / "stale-resource.ipa"
        stale_sha = build_ipa(stale, core=core, runtime=runtime, resources=resources,
                              packaged_resources={**resources, "dsp_coef.bin": b"other"})
        expect_refusal("resource differing from identity",
                       lambda: run(stale, temp / "o3", stale_sha, core, runtime))

        foreign = temp / "foreign-host.ipa"
        foreign_sha = build_ipa(foreign, core=core, runtime=runtime, resources=resources,
                                identity_overrides={"host_commit": "2" * 40})
        expect_refusal("other donor host commit",
                       lambda: run(foreign, temp / "o4", foreign_sha, core, runtime))

        escape = temp / "escape.ipa"
        escape_sha = build_ipa(escape, core=core, runtime=runtime, resources={"../outside": b"x"})
        expect_refusal("resource path escaping the artifact",
                       lambda: run(escape, temp / "o5", escape_sha, core, runtime))
    print("KartPad donor restoration from packaged IPA: OK")


if __name__ == "__main__":
    sys.exit(main())
