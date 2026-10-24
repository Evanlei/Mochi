"""Build a credential-free, architecture-specific private beta on this Mac."""

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build" / "beta"
ENGINE = OUTPUT / "engine" / "mochi-backend"


def run(*command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, cwd=ROOT, **kwargs)


def build_engine():
    model = ROOT / "backend/.models/intent-energy"
    if not (model / "manifest.json").is_file():
        raise SystemExit("Prepare the pinned semantic model first: bash scripts/setup.sh")
    run(ROOT / "backend/.venv/bin/python", "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir",
        "--name", "mochi-backend", "--distpath", OUTPUT / "engine", "--workpath", OUTPUT / "engine-work",
        "--specpath", OUTPUT / "engine-spec", "--paths", ROOT / "backend",
        "--collect-all", "fastembed", "--collect-all", "onnxruntime", "--copy-metadata", "fastembed",
        "--hidden-import", "uvicorn.logging", "--hidden-import", "uvicorn.loops.asyncio",
        "--hidden-import", "uvicorn.protocols.http.h11_impl", "--hidden-import", "uvicorn.lifespan.on",
        "--add-data", f"{model}:.models/intent-energy",
        "--add-data", f"{ROOT / 'backend/data'}:data", ROOT / "backend/serve.py")


def smoke_engine():
    # Disposable fixture mode, empty credentials and a separate port never alter
    # personal taste, the development server or real Spotify playback.
    with tempfile.TemporaryDirectory(prefix="mochi-bundle-check-") as directory:
        environment = {key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "TMPDIR", "LANG"}}
        environment.update(MOCHI_CATALOG_MODE="sample", LASTFM_API_KEY="", MOCHI_DATA_DIRECTORY=directory)
        process = subprocess.Popen([str(ENGINE / "mochi-backend"), "--port", "18763"], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 40
            while True:
                try:
                    with urllib.request.urlopen("http://127.0.0.1:18763/status", timeout=2) as response:
                        status = json.load(response)
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() > deadline:
                        error = process.stderr.read().decode(errors="replace") if process.poll() is not None else "startup timed out"
                        raise RuntimeError("Bundled engine failed its fixture check: " + error[-2000:])
                    time.sleep(0.2)
            assert status["service"] == "mochi" and status["semantic_model_installed"]
            request = urllib.request.Request("http://127.0.0.1:18763/listening-request",
                data=json.dumps({"prompt": "relaxing piano music, no vocals"}).encode(), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=45) as response:
                selected = json.load(response)["selection"]
            assert selected["catalog_kind"] == "fictional_sample" and selected["tracks"]
            assert selected["method"] == "semantic", "Bundled engine lost the semantic model; refusing a silent quality downgrade"
            report = {"engine_started": True, "catalog": selected["catalog_kind"], "ranking": selected["method"],
                      "fixture_tracks": len(selected["tracks"]), "architecture": platform.machine(), "real_playback_tested": False}
            (OUTPUT / "bundle-validation.json").write_text(json.dumps(report, indent=2) + "\n")
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()


def build_app():
    run("xcodebuild", "-quiet", "-project", ROOT / "Mochi/Mochi.xcodeproj", "-scheme", "Mochi", "-configuration", "Release",
        "-destination", f"platform=macOS,arch={platform.machine()}", "-derivedDataPath", OUTPUT / "native", "CODE_SIGNING_ALLOWED=NO", "build")
    app = OUTPUT / "Mochi.app"
    if app.exists(): shutil.rmtree(app)
    shutil.copytree(OUTPUT / "native/Build/Products/Release/Mochi.app", app, symlinks=True)
    shutil.copytree(ENGINE, app / "Contents/Resources/Engine", symlinks=True)
    notices = app / "Contents/Resources/Notices"
    notices.mkdir()
    python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
    if not python_license.is_file():
        python_license = Path(sys.base_prefix) / f"lib/python{sys.version_info.major}.{sys.version_info.minor}/LICENSE.txt"
    if not python_license.is_file():
        raise RuntimeError("The bundled Python license could not be found")
    shutil.copy2(python_license, notices / "PYTHON-LICENSE.txt")
    inventory = []
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name", "unknown")
        inventory.append({"name": name, "version": distribution.version,
                          "license": distribution.metadata.get("License-Expression", "See dependency notices")})
        for entry in distribution.files or []:
            text = str(entry)
            if ".dist-info/" not in text: continue
            relative = text.split(".dist-info/", 1)[1]
            if relative.startswith("licenses/") or Path(relative).name.upper().startswith(("LICENSE", "COPYING")):
                source = Path(distribution.locate_file(entry))
                if source.is_file():
                    destination = notices / re.sub(r"[^A-Za-z0-9_.-]", "_", name) / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
    (notices / "dependency-inventory.json").write_text(json.dumps(sorted(inventory, key=lambda row: row["name"].lower()), indent=2) + "\n")
    shutil.copy2(ROOT / "docs/THIRD_PARTY.md", notices / "THIRD_PARTY.md")
    for path in app.rglob("*"):
        if path.name == ".env" or path.suffix in {".sqlite3", ".sqlite", ".db"}:
            raise RuntimeError(f"Personal/configuration data must not enter a release: {path.name}")
    entitlements = OUTPUT / "app-entitlements.plist"
    import plistlib
    original = plistlib.loads((ROOT / "Mochi/SpotifyAutomation.entitlements").read_bytes())
    original.update({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                     "com.apple.security.network.server": True, "com.apple.security.files.user-selected.read-only": True})
    entitlements.write_bytes(plistlib.dumps(original))
    child_entitlements = OUTPUT / "engine-entitlements.plist"
    child_entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}))
    run("codesign", "--force", "--sign", "-", "--entitlements", child_entitlements,
        app / "Contents/Resources/Engine/mochi-backend")
    run("codesign", "--force", "--sign", "-", "--entitlements", entitlements, app)
    run("codesign", "--verify", "--deep", "--strict", app)
    archive = OUTPUT / f"Mochi-private-beta-{platform.machine()}.zip"
    share = OUTPUT / "Mochi Private Beta"
    if share.exists(): shutil.rmtree(share)
    shutil.copytree(app, share / "Mochi.app", symlinks=True)
    shutil.copy2(ROOT / "docs/PRIVATE_BETA.md", share / "START_HERE.md")
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", share, archive)
    print(f"Private beta: {archive}")
    print("Credentials are configured in Setup & Settings. Public distribution still requires signing/notarization and provider access.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-only", action="store_true")
    parser.add_argument("--skip-engine", action="store_true")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if not args.skip_engine: build_engine()
    smoke_engine()
    if not args.engine_only: build_app()
