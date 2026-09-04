#!/usr/bin/env python3
"""Small idempotent compile/runtime fixes applied after v2 materialization."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old in text:
        path.write_text(text.replace(old, new), encoding="utf-8")


def main() -> None:
    service = ROOT / "lib/services/dolphin_internal_v2_service.dart"
    replace(
        service,
        "throw const FileSystemException('Copied image length mismatch');",
        "throw FileSystemException('Copied image length mismatch');",
    )
    replacements = {
        "await output.delete().catchError((_) {});": "await _deleteIfExists(output);",
        "await temporary.delete().catchError((_) {});": "await _deleteIfExists(temporary);",
        "await target.delete().catchError((_) {});": "await _deleteIfExists(target);",
        "await marker.delete().catchError((_) {});": "await _deleteIfExists(marker);",
    }
    for old, new in replacements.items():
        replace(service, old, new)

    text = service.read_text(encoding="utf-8")
    helper = """  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup must not replace the original diagnostic.
    }
  }

"""
    anchor = "  static Future<File> _uniqueDestination(Directory directory, String name) async {\n"
    if helper not in text:
        if anchor not in text:
            raise SystemExit("Dolphin service cleanup helper anchor missing")
        text = text.replace(anchor, helper + anchor, 1)
        service.write_text(text, encoding="utf-8")

    plugin = ROOT / "packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm"
    text = plugin.read_text(encoding="utf-8")
    if "#import <stdio.h>" not in text:
        text = text.replace("#import <poll.h>\n", "#import <poll.h>\n#import <stdio.h>\n", 1)
    text = text.replace(
        "NSData* pairingData = [NSData dataWithContentsOfFile:pairingPath options:0 error:nil];",
        "NSData* pairingData = [[NSData alloc] initWithContentsOfFile:pairingPath "
        "options:NSDataReadingMappedIfSafe error:nil];",
    )
    plugin.write_text(text, encoding="utf-8")

    # Remove temporary connector checkpoints; they are not implementation files.
    for path in (ROOT / "build-utils").glob(".dolphin-v2-*"):
        path.unlink(missing_ok=True)
    for path in (ROOT / "build-utils").glob("dolphin_isolation_marker*.txt"):
        path.unlink(missing_ok=True)

    print("Applied idempotent Dolphin v2 compile fixes.")


if __name__ == "__main__":
    main()
