# Third-party software and data

Mochi's beta bundle includes Python, FastAPI/Starlette/Pydantic, HTTPX, NumPy,
ONNX Runtime, FastEmbed and their runtime dependencies. PyInstaller builds the
standalone engine. The bundle's `Contents/Resources/Notices` directory contains
available dependency license files and a version inventory of the build environment.
The inventory includes build tools as well as runtime packages.

The semantic model is `BAAI/bge-small-en-v1.5`, supplied as the MIT-licensed
quantized ONNX model `Qdrant/bge-small-en-v1.5-onnx-Q`, pinned by revision and
SHA-256 manifest. Its model card is included with the model files.

- Original model: https://huggingface.co/BAAI/bge-small-en-v1.5
- Quantized model: https://huggingface.co/Qdrant/bge-small-en-v1.5-onnx-Q
- FastEmbed: https://github.com/qdrant/fastembed
- ONNX Runtime: https://github.com/microsoft/onnxruntime
- PyInstaller: https://pyinstaller.org/

Music discovery uses Last.fm's API under its own terms, with visible attribution
and links to recordings. Spotify supplies native playback, optional catalog
matching and artwork under its developer terms. No provider catalog, cached
music data, Spotify tokens, Last.fm keys or personal taste database is included
in the beta archive.

- Last.fm terms: https://www.last.fm/api/tos
- Spotify policy: https://developer.spotify.com/policy
