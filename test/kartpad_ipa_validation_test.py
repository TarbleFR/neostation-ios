#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import tempfile
import zipfile
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build-utils"))
from validate_kartpad_ipa import validate_absent


def make_ipa(path: Path, *, with_core: bool = False, with_identity: bool = False,
             with_nested_app: bool = False) -> None:
    app = "Payload/Runner.app/"
    info = plistlib.dumps({
        "CFBundleIdentifier": "com.neogamelab.neostation",
        "CFBundleVersion": "323",
    })
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(app + "Info.plist", info)
        if with_core:
            z.writestr(
                app + "Frameworks/KartPadCore.framework/KartPadCore",
                b"not-a-real-macho",
            )
        if with_identity:
            z.writestr(app + "KartPad-native-identity.json", b"{}")
        if with_nested_app:
            z.writestr(app + "KartPad.app/Info.plist", info)


def expect_failure(path: Path, fragment: str) -> None:
    try:
        validate_absent(path, "323")
    except AssertionError as error:
        assert fragment in str(error), (fragment, error)
    else:
        raise AssertionError(f"expected failure containing {fragment!r}")


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)

        clean = root / "clean.ipa"
        make_ipa(clean)
        report = validate_absent(clean, "323")
        assert report["kartPadCorePresent"] is False
        assert report["standaloneKartPadPresent"] is False

        stale_core = root / "stale-core.ipa"
        make_ipa(stale_core, with_core=True)
        expect_failure(stale_core, "Unexpected KartPadCore.framework")

        stale_identity = root / "stale-identity.ipa"
        make_ipa(stale_identity, with_identity=True)
        expect_failure(stale_identity, "Unexpected KartPad identity")

        nested_app = root / "nested-app.ipa"
        make_ipa(nested_app, with_nested_app=True)
        expect_failure(nested_app, "Standalone KartPad app")

    print("PASS: KartPad IPA absence validator rejects stale/nested runtime payloads")


if __name__ == "__main__":
    main()
