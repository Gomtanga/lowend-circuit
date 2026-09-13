#!/usr/bin/env python3
"""Exercise staged app replacement without building Swift or accessing devices."""
import os
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check_build_script() -> None:
    with tempfile.TemporaryDirectory(prefix="lowend-build-script-check-") as temporary:
        folder = Path(temporary)
        commands = folder / "commands"
        products = folder / "products"
        commands.mkdir()
        products.mkdir()
        shader = ROOT / "SystemAudioProcessor/Shaders/SpectrumShaders.metal"
        bundle = products / "SystemAudioProcessor_SystemAudioProcessor.bundle"
        bundle.mkdir()
        shutil.copy2(shader, bundle / shader.name)
        scripts = {
            commands / "swift": '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["LOWEND_MOCK_SWIFT_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if "--show-bin-path" in sys.argv:
    print(os.environ["LOWEND_MOCK_BIN"])
''',
            commands / "codesign": '#!/bin/sh\ncase " $* " in *" --verify "*) if [ "${LOWEND_MOCK_FAIL_SIGN:-0}" = 1 ]; then exit 43; fi;; esac\n',
            commands / "plutil": '#!/bin/sh\nexit 0\n',
            products / "LowEndSupportChecks": '#!/bin/sh\nexit 0\n',
            products / "SystemAudioProcessor": '''#!/bin/sh
case "$*" in
  --self-test) if [ "${LOWEND_MOCK_FAIL_SELFTEST:-0}" = 1 ]; then exit 42; fi; exit 0;;
  --help) printf '%s\\n' '--self-test --ui-self-test --benchmark-output-conditioning'; exit 0;;
  *) if [ "${LOWEND_MOCK_FAIL_CLI:-0}" = 1 ]; then exit 0; fi; echo 'Invalid command'; exit 1;;
esac
''',
        }
        for destination, text in scripts.items():
            destination.write_text(text)
            destination.chmod(0o755)
        app = folder / "output/LowEnd Native Audio.app"
        app.mkdir(parents=True)
        sentinel = app / "previous-sentinel"
        sentinel.write_text("previous validated app")
        environment = os.environ.copy()
        environment.pop("LOWEND_SWIFT_SDK", None)
        environment.pop("LOWEND_SWIFT_BUILD_SYSTEM", None)
        environment.update(
            PATH=str(commands) + os.pathsep + environment["PATH"],
            LOWEND_MOCK_BIN=str(products), LOWEND_BUILD_DIR=str(folder / "build"),
            LOWEND_APP_DIR=str(app), LOWEND_BUILD_NUMBER="123",
            LOWEND_MOCK_SWIFT_LOG=str(folder / "swift-args.jsonl"),
        )
        for failure_key, expected_code in [("LOWEND_MOCK_FAIL_SIGN", 43),
                                           ("LOWEND_MOCK_FAIL_SELFTEST", 42),
                                           ("LOWEND_MOCK_FAIL_CLI", 1)]:
            attempt = environment | {failure_key: "1"}
            result = subprocess.run([str(ROOT / "scripts/build-native-system-audio-app.sh")],
                                    env=attempt, capture_output=True, text=True)
            assert result.returncode == expected_code, (result.returncode, result.stderr)
            assert sentinel.read_text() == "previous validated app"
            assert not list(app.parent.glob(".lowend-stage.*"))
        result = subprocess.run([str(ROOT / "scripts/build-native-system-audio-app.sh")],
                                env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert not sentinel.exists()
        assert (app / "Contents/MacOS/LowEnd Native Audio").is_file()
        assert (app / "Contents/Resources" / bundle.name / shader.name).read_bytes() == shader.read_bytes()
        with (app / "Contents/Info.plist").open("rb") as file:
            metadata = plistlib.load(file)
            assert metadata["CFBundleVersion"] == "123"
            assert metadata["LCCaptureLeaseVersion"] == 1
        assert not list(app.parent.glob(".lowend-stage.*"))
        calls = [json.loads(line) for line in (folder / "swift-args.jsonl").read_text().splitlines()]
        assert all("--sdk" not in args and "--build-system" not in args for args in calls)
        sdk = str(folder / "SDK with spaces/MacOSX.sdk")
        result = subprocess.run([str(ROOT / "scripts/build-native-system-audio-app.sh")],
                                env=environment | {"LOWEND_SWIFT_SDK": sdk, "LOWEND_SWIFT_BUILD_SYSTEM": "native"},
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        extra = [json.loads(line) for line in (folder / "swift-args.jsonl").read_text().splitlines()][len(calls):]
        assert len(extra) == 3
        for args in extra:
            assert args[args.index("--sdk") + 1] == sdk
            assert args[args.index("--build-system") + 1] == "native"

        # swiftbuild uses a standard macOS bundle instead of the native flat one.
        nested_resources = bundle / "Contents/Resources"
        nested_resources.mkdir(parents=True)
        (bundle / shader.name).rename(nested_resources / shader.name)
        with (bundle / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundlePackageType": "BNDL"}, file)
        result = subprocess.run([str(ROOT / "scripts/build-native-system-audio-app.sh")],
                                env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        delivered_shader = app / "Contents/Resources" / bundle.name / "Contents/Resources" / shader.name
        assert delivered_shader.read_bytes() == shader.read_bytes()
        assert not (app / "Contents/Resources" / bundle.name / shader.name).exists()
        preserved_files = {str(path.relative_to(app)): path.read_bytes()
                           for path in app.rglob("*") if path.is_file()}
        (nested_resources / shader.name).unlink()
        result = subprocess.run([str(ROOT / "scripts/build-native-system-audio-app.sh")],
                                env=environment, capture_output=True, text=True)
        assert result.returncode == 1, result.stderr
        assert "missing SpectrumShaders.metal" in result.stderr
        assert {str(path.relative_to(app)): path.read_bytes()
                for path in app.rglob("*") if path.is_file()} == preserved_files
        assert not list(app.parent.glob(".lowend-stage.*"))
    print("BuildScriptChecks: verification failures preserve the old app; successful staging replaces it")
    print("BuildScriptChecks: flat and macOS Contents bundles pass; missing shader preserves the old app")
    print("BuildScriptChecks: Swift/signing are mocked; actual bundle validation remains separate")


if __name__ == "__main__":
    check_build_script()
