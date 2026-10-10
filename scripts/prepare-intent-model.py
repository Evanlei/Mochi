"""Download a pinned public model once; no requests or credentials are uploaded."""

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from semantic import MODEL_DIRECTORY, MODEL_FILES, MODEL_NAME, MODEL_REPOSITORY, MODEL_REVISION


def main():
    from huggingface_hub import snapshot_download

    MODEL_DIRECTORY.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id=MODEL_REPOSITORY, revision=MODEL_REVISION,
        local_dir=MODEL_DIRECTORY, allow_patterns=[*MODEL_FILES, "README.md"])
    checksums = {name: hashlib.sha256((MODEL_DIRECTORY / name).read_bytes()).hexdigest()
                 for name in MODEL_FILES}
    manifest = {"model": MODEL_NAME, "repository": MODEL_REPOSITORY,
                "revision": MODEL_REVISION, "sha256": checksums}
    (MODEL_DIRECTORY / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {MODEL_NAME} locally. Restart the backend to load it.")


if __name__ == "__main__":
    main()
