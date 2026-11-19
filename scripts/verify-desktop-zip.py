"""Check the extracted desktop release ZIP and run the normal ingestion smoke test."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def verify_cli(executable, data):
    data.mkdir()
    command = [executable, "--data-dir", data]
    result = subprocess.run([*command, "--version"], capture_output=True, encoding="utf-8")
    if result.returncode != 0 or result.stderr:
        raise SystemExit("CLI --version failed.")
    version = json.loads(result.stdout)
    if version.get("format_version") != 1 or version.get("command") != "version" or not version["data"]["version"]:
        raise SystemExit("CLI --version returned an invalid response.")
    print(f"PASS: CLI --version ({version['data']['version']})", flush=True)
    result = subprocess.run([*command, "status"], capture_output=True, encoding="utf-8")
    if result.returncode != 2 or result.stdout:
        raise SystemExit("CLI status did not refuse a missing ledger with exit code 2.")
    error = json.loads(result.stderr)
    if error.get("format_version") != 1 or error["error"]["code"] != "no_ledger" or any(data.iterdir()):
        raise SystemExit("CLI status returned an invalid error or wrote to the data directory.")
    print("PASS: CLI status refused a missing ledger without writing data", flush=True)


def verify(archive):
    with tempfile.TemporaryDirectory(prefix="token-lens-zip-", dir=os.environ.get("RUNNER_TEMP")) as folder:
        root = Path(folder)
        paths = ["LICENSE", "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_LICENSES.txt"]
        if sys.platform == "win32":
            with zipfile.ZipFile(archive) as package:
                package.extractall(root)
            executable = "token-lens.exe"
            cli = "token-lens-cli.exe"
            paths.extend(["flutter_windows.dll", "rust_lib_token_lens.dll",
                          "data/icudtl.dat", "data/app.so",
                          "data/flutter_assets/NOTICES.Z"])
        elif sys.platform == "darwin":
            subprocess.run(["ditto", "-x", "-k", archive, root], check=True)
            executable = "Token Lens.app/Contents/MacOS/Token Lens"
            cli = "Token Lens.app/Contents/MacOS/token-lens-cli"
            frameworks = "Token Lens.app/Contents/Frameworks"
            paths.extend([f"{frameworks}/FlutterMacOS.framework/FlutterMacOS",
                          f"{frameworks}/App.framework/Resources/flutter_assets/NOTICES.Z"])
        else:
            raise SystemExit("Desktop ZIP smoke requires Windows or macOS.")
        for name in [executable, cli, *paths]:
            path = root / name
            if not path.is_file() or path.stat().st_size == 0:
                raise SystemExit(f"Missing or empty ZIP entry: {name}")
            print(f"PASS: {name} ({path.stat().st_size} bytes)", flush=True)
        verify_cli(root / cli, root / "empty-cli-data")
        smoke = Path(__file__).with_name("smoke-desktop.py")
        subprocess.run([sys.executable, smoke, root / executable], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    verify(args.archive.resolve(strict=True))


if __name__ == "__main__":
    main()
