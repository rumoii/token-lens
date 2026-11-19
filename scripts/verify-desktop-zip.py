"""Check the extracted desktop release ZIP and run the normal ingestion smoke test."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def verify(archive):
    with tempfile.TemporaryDirectory(prefix="token-lens-zip-", dir=os.environ.get("RUNNER_TEMP")) as folder:
        root = Path(folder)
        paths = ["LICENSE", "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_LICENSES.txt"]
        if sys.platform == "win32":
            with zipfile.ZipFile(archive) as package:
                package.extractall(root)
            executable = "token-lens.exe"
            paths.extend(["flutter_windows.dll", "rust_lib_token_lens.dll",
                          "data/icudtl.dat", "data/app.so",
                          "data/flutter_assets/NOTICES.Z"])
        elif sys.platform == "darwin":
            subprocess.run(["ditto", "-x", "-k", archive, root], check=True)
            executable = "Token Lens.app/Contents/MacOS/Token Lens"
            frameworks = "Token Lens.app/Contents/Frameworks"
            paths.extend([f"{frameworks}/FlutterMacOS.framework/FlutterMacOS",
                          f"{frameworks}/App.framework/Resources/flutter_assets/NOTICES.Z"])
        else:
            raise SystemExit("Desktop ZIP smoke requires Windows or macOS.")
        for name in [executable, *paths]:
            path = root / name
            if not path.is_file() or path.stat().st_size == 0:
                raise SystemExit(f"Missing or empty ZIP entry: {name}")
            print(f"PASS: {name} ({path.stat().st_size} bytes)", flush=True)
        smoke = Path(__file__).with_name("smoke-desktop.py")
        subprocess.run([sys.executable, smoke, root / executable], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    verify(args.archive.resolve(strict=True))


if __name__ == "__main__":
    main()
