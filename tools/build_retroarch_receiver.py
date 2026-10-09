"""Build the reviewed RetroArch receiver, using official prebuilt cores only.

The resulting IPA is sealed for SideStore, which must apply Apple provisioning.
This never accesses or modifies an installed application's documents.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "receiver-source"
INFO = ROOT / "receiver-info"
DEPS = ROOT / ".receiver-deps"
OUT = ROOT / "receiver-delivery"
REVISION = "a7363feb909391c3217b91c30e81547e8208d6d5"
INFO_REVISION = "5a74858ab2f7a50cebb5a6330895bc38899531c0"
PROOF = "3c70b5f4adb80232d3c50d0b648520c7db5afe2c"
PRODUCT = "00285ba5cfec694d59e1ca2bcf9de31418fd4e1a"
BASE = "https://buildbot.libretro.com/nightly/apple/ios-arm64/latest/"
BUILD = "781"
# Explicit core bindings present in the supplied playlists, not guessed paths.
REQUIRED = {"gambatte", "nestopia", "mupen64plus_next", "azahar",
            "genesis_plus_gx_wide", "desmume", "mednafen_psx_hw", "ppsspp",
            "mgba", "picodrive", "genesis_plus_gx", "snes9x", "fbneo"}


def run(*args, cwd=None):
    return subprocess.check_output([str(x) for x in args], cwd=cwd, text=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(name, data):
    OUT.mkdir(exist_ok=True)
    (OUT / name).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def measure(label, operation):
    start = time.monotonic()
    try:
        result = operation()
    finally:
        OUT.mkdir(exist_ok=True)
        with (OUT / "timings.jsonl").open("a") as handle:
            handle.write(json.dumps({"phase": label, "seconds": time.monotonic() - start}) + "\n")
    return result


def verify():
    for ref, paths in ((PRODUCT, ["lib", "packages", "native", "assets", "pubspec.yaml", "pubspec.lock"]),
                       (PROOF, ["docs/upstream/retroarch-initial-scene-url.patch",
                                "tools/test_retroarch_source_receiver.py",
                                "test/fixtures/retroarch_handoff"])):
        changed = run("git", "diff", "--name-only", ref, "HEAD", "--", *paths, cwd=ROOT).splitlines()
        if changed:
            raise ValueError("Previously tested inputs changed: " + repr(changed))
    record = json.loads(run("gh", "api", "repos/TarbleFR/neostation-ios/actions/runs/37857669052"))
    if record["head_sha"] != PROOF or record["conclusion"] != "success":
        raise ValueError("Exact-source receiver proof unavailable")
    product = json.loads(run("gh", "api", "repos/TarbleFR/neostation-ios/actions/runs/37847695065"))
    if product["head_sha"] != PRODUCT or product["conclusion"] != "success":
        raise ValueError("Product baseline evidence unavailable")
    save("reused-validation.json", {"receiverProofRun": record["html_url"],
         "receiverProofCommit": PROOF, "productRun": product["html_url"],
         "productCommit": PRODUCT, "testedInputsIdentical": True,
         "testsExecutedAgain": False, "gameExecutionValidated": False})
    save("environment.json", {"xcode": run("xcodebuild", "-version"),
         "sdk": run("xcrun", "--sdk", "iphoneos", "--show-sdk-version").strip(),
         "cpuCount": os.cpu_count(), "memoryBytes": int(run("sysctl", "-n", "hw.memsize")),
         "platform": run("sw_vers"), "hostCommit": run("git", "rev-parse", "HEAD", cwd=ROOT).strip()})


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read(), {"lastModified": response.headers.get("Last-Modified"),
                                 "etag": response.headers.get("ETag")}


def cores():
    script = (SOURCE / "pkg/apple/update-cores.sh").read_text()
    block = re.search(r"appstore_cores=\(\s*(.*?)\n\)", script, re.S).group(1)
    selected = {line.strip() for line in block.splitlines()
                if line.strip() and not line.strip().startswith("#")} | REQUIRED
    DEPS.mkdir(exist_ok=True)
    manifest = DEPS / "manifest.json"
    if manifest.exists():
        data = json.loads(manifest.read_text())
        if data["selection"] != sorted(selected):
            raise ValueError("Cached core selection differs")
        for core in data["cores"]:
            if sha((DEPS / core["file"]).read_bytes()) != core["sha256"]:
                raise ValueError("Cached core hash differs: " + core["file"])
        save("prebuilt-cores.json", {**data, "cacheReused": True})
        return data
    listing = fetch(BASE)[0].decode()
    names = set(re.findall(r'href="[^" ]*/([^"/]+\.dylib\.zip)"', listing))
    requests, unavailable = [], []
    for name in sorted(selected):
        possibilities = [name + "_libretro_ios.dylib.zip", name + "_libretro.dylib.zip"]
        found = next((value for value in possibilities if value in names), None)
        if found:
            requests.append((name, found))
        else:
            unavailable.append(name)
    if REQUIRED.intersection(unavailable):
        raise ValueError("Required supplied-playlist cores unavailable: " + repr(sorted(REQUIRED.intersection(unavailable))))

    def download(item):
        name, filename = item
        data, headers = fetch(BASE + filename)
        dylib = filename[:-4]
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            files = [entry for entry in archive.infolist() if entry.filename == dylib and not entry.is_dir()]
            if len(files) != 1:
                raise ValueError("Expected exact official core member: " + dylib)
            payload = archive.read(files[0])
        (DEPS / dylib).write_bytes(payload)
        (DEPS / filename).write_bytes(data)
        return {"core": name, "file": dylib, "url": BASE + filename,
                "zipSha256": sha(data), "sha256": sha(payload), "bytes": len(payload), **headers}

    with ThreadPoolExecutor(max_workers=4) as pool:
        records = list(pool.map(download, requests))
    data = {"selection": sorted(selected), "unavailableOptionalCores": unavailable,
            "cores": records, "emulatorCoresCompiled": 0,
            "testFlightCoreIdentityEstablished": False}
    manifest.write_text(json.dumps(data, indent=2) + "\n")
    save("prebuilt-cores.json", {**data, "cacheReused": False})
    return data


def prepare():
    if run("git", "rev-parse", "HEAD", cwd=SOURCE).strip() != REVISION:
        raise ValueError("Unexpected RetroArch source revision")
    if run("git", "rev-parse", "HEAD", cwd=INFO).strip() != INFO_REVISION:
        raise ValueError("Unexpected official core-info revision")
    data = measure("prebuilt_core_dependencies", cores)
    # Validate every official download before including it. A directory label
    # is insufficient evidence of the Mach-O platform. Never retag macOS code
    # as iOS or weaken the final IPA checks.
    sys.path.insert(0, str(ROOT / "packages/dolphin_internal_bridge/ci"))
    from verify_ipa import macho
    included, excluded = [], []
    for record in data["cores"]:
        image = macho((DEPS / record["file"]).read_bytes())
        compatible = (image["platform"] == 2 and image["minimumOS"] is not None
                      and tuple(map(int, image["minimumOS"].split("."))) <= (18, 0, 0))
        if compatible:
            included.append(record)
        elif record["core"] in REQUIRED:
            raise ValueError("Required core is incompatible with physical iOS 18: " + record["core"])
        else:
            excluded.append({**record, "platform": image["platform"],
                             "minimumOS": image["minimumOS"], "reason": "incompatible physical iOS platform or minimum OS"})
    report = json.loads((OUT / "prebuilt-cores.json").read_text())
    save("prebuilt-cores.json", {**report, "cores": included,
         "downloadedCoreCount": len(data["cores"]), "excludedIncompatibleCores": excluded})
    print("Validated", len(included), "physical iOS cores; explicitly excluded", [r["core"] for r in excluded])
    patch = ROOT / "docs/upstream/retroarch-initial-scene-url.patch"
    run("git", "apply", "--check", patch, cwd=SOURCE)
    run("git", "apply", patch, cwd=SOURCE)
    # Replace only packaging: upstream make-frameworks mutates the downloaded
    # dylibs' load commands. Our packer preserves their original code and ABI.
    project = SOURCE / "pkg/apple/RetroArch_iOS13.xcodeproj/project.pbxproj"
    text = project.read_text()
    if text.count("./make-frameworks.sh\\n") != 1:
        raise ValueError("Unreviewed iOS core packaging phase")
    text = text.replace("./make-frameworks.sh\\n",
                        'python3 \\\"$RECEIVER_PACKER\\\" pack\\n')
    project.write_text(text)
    # Preserve upstream assets and overlays. Refresh only official core metadata
    # needed for DETECT entries, at a pinned commit.
    assets = SOURCE / "pkg/apple/assets.zip"
    original = assets.read_bytes()
    with zipfile.ZipFile(io.BytesIO(original)) as source:
        with zipfile.ZipFile(assets.with_suffix(".new.zip"), "w", zipfile.ZIP_DEFLATED) as result:
            for entry in source.infolist():
                if not entry.filename.startswith(("info/", "__MACOSX/._info", "__MACOSX/info/")):
                    result.writestr(entry, source.read(entry))
            for info in sorted(INFO.glob("*.info")):
                result.write(info, "info/" + info.name)
    assets.with_suffix(".new.zip").replace(assets)
    save("source-identity.json", {"retroArchCommit": REVISION, "coreInfoCommit": INFO_REVISION,
         "receiverPatchSha256": sha(patch.read_bytes()), "originalAssetsSha256": sha(original),
         "packagedAssetsSha256": sha(assets.read_bytes()), "receiverSourceSha256": sha((SOURCE / "ui/drivers/ui_cocoatouch.m").read_bytes()),
         "urlScheme": "retroarch", "bundleIdentifier": "com.libretro.RetroArchiOS11",
         "privateCandidateBuild": BUILD, "testFlightPatched": False,
         "installedUserDocumentsTouched": False})


def pack():
    output = Path(os.environ["BUILT_PRODUCTS_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"]
    output.mkdir(parents=True, exist_ok=True)
    data = json.loads((OUT / "prebuilt-cores.json").read_text())
    for record in data["cores"]:
        source = DEPS / record["file"]
        if sha(source.read_bytes()) != record["sha256"]:
            raise ValueError("Prebuilt core modified before packaging")
        name = source.stem.removesuffix("_ios").replace("_", ".")
        target = output / (name + ".framework")
        target.mkdir(exist_ok=True)
        shutil.copy2(source, target / name)
        (target / name).chmod(0o755)
        # Binary minimum OS is checked after signing, never rewritten here.
        (target / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": name, "CFBundleName": name,
            "CFBundleIdentifier": name, "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0", "CFBundlePackageType": "FMWK",
            "CFBundleInfoDictionaryVersion": "6.0", "MinimumOSVersion": "18.0"}))
    molten = SOURCE / "pkg/apple/Frameworks/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"
    if not molten.is_dir():
        raise ValueError("Pinned iPhoneOS MoltenVK framework missing")
    shutil.copytree(molten, output / "MoltenVK.framework", dirs_exist_ok=True)
    print("Packaged", len(data["cores"]), "precompiled cores without modifying their binaries")


def seal():
    sys.path.insert(0, str(ROOT / "build-utils"))
    from delivery_benchmark import payload_fingerprint
    from sign_delivery import sign
    sys.path.insert(0, str(ROOT / "packages/dolphin_internal_bridge/ci"))
    from verify_ipa import macho
    archive = ROOT / "receiver-build/RetroArch.xcarchive/Products/Applications/RetroArch.app"
    stage = ROOT / "receiver-build/export"
    app = stage / "Payload/RetroArch.app"
    shutil.copytree(archive, app, dirs_exist_ok=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if (info["CFBundleVersion"] != BUILD or info["CFBundleIdentifier"] != "com.libretro.RetroArchiOS11"
            or info["MinimumOSVersion"] != "18.0"
            or info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] != ["retroarch"]):
        raise ValueError("Unexpected app identity, minimum OS, build or public scheme")
    if not info.get("UIApplicationSceneManifest"):
        raise ValueError("Real scene receiver not enabled")
    identity = json.loads((OUT / "source-identity.json").read_text())
    (app / "NeoStation-receiver-build-identity.json").write_text(json.dumps(identity, indent=2))
    licenses = app / "Receiver-source-notices"
    licenses.mkdir(exist_ok=True)
    for filename in ("COPYING", "COPYING.app", "COPYING.all"):
        source = SOURCE / filename
        if source.is_file():
            shutil.copy2(source, licenses / filename)
    shutil.copy2(ROOT / "docs/upstream/retroarch-initial-scene-url.patch", licenses)
    images = {}
    structures = {}
    for path in app.rglob("*"):
        if path.is_file() and path.open("rb").read(4) == b"\xcf\xfa\xed\xfe":
            path.chmod(0o755)
            name = str(path.relative_to(app))
            image = macho(path.read_bytes())
            if image["platform"] != 2 or tuple(map(int, image["minimumOS"].split("."))) > (18, 0, 0):
                raise ValueError("Incompatible device image: " + name + " " + repr(image["platform"]))
            images[name] = payload_fingerprint(path.read_bytes())
            structures[name] = {key: image[key] for key in ("platform", "minimumOS", "dependencies")}
    records = json.loads((OUT / "prebuilt-cores.json").read_text())["cores"]
    for record in records:
        name = Path(record["file"]).stem.removesuffix("_ios").replace("_", ".")
        relative = "Frameworks/" + name + ".framework/" + name
        if images.get(relative) != payload_fingerprint((DEPS / record["file"]).read_bytes()):
            raise ValueError("Core instructions or ABI changed: " + name)
    measure("nested_signatures", lambda: sign(app, OUT / "signature.json"))
    if any(payload_fingerprint((app / name).read_bytes()) != value for name, value in images.items()):
        raise ValueError("Signing altered code, data or ABI")
    ipa = OUT / ("RetroArch-Receiver-Build" + BUILD + ".ipa")
    run("/usr/bin/zip", "-qry", ipa, "Payload", cwd=stage)
    run("unzip", "-tq", ipa)
    with tempfile.TemporaryDirectory() as temp:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(temp)
            assets = next(name for name in archive.namelist() if name.endswith("/assets.zip"))
            with zipfile.ZipFile(io.BytesIO(archive.read(assets))) as resources:
                if "info/mgba_libretro.info" not in resources.namelist():
                    raise ValueError("Required core metadata missing")
        unpacked = Path(temp) / "Payload/RetroArch.app"
        for name in images:
            path = unpacked / name
            path.chmod(0o755)
            if payload_fingerprint(path.read_bytes()) != images[name]:
                raise ValueError("IPA export altered compiled image")
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", unpacked)
    save("artifact-identity.json", {"name": ipa.name, "bytes": ipa.stat().st_size,
         "sha256": sha(ipa.read_bytes()), "images": structures,
         "coreCount": len(records), "allCoreInstructionsAndABIUnchanged": True,
         "sideStoreAppleReSigningRequired": True, "physicalDeviceTested": False,
         "actualGameLaunchValidated": False, "testFlightBinaryModified": False})
    print("IPA sealed and final ZIP signatures verified:", ipa.name, ipa.stat().st_size)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("verify", "prepare", "pack", "seal"))
    args = parser.parse_args()
    if args.operation == "seal":
        measure("signature_and_ipa_export", seal)
    else:
        globals()[args.operation]()
