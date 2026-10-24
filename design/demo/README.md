# README demo

`mochi-demo.gif` is a 14-second looping preview of Mochi's production SwiftUI
views and mascot poses. `mochi-demo.png` is a static alternative for readers who
prefer a still image.

The sequence shows a greeting, prompt entry, the thinking pose, recommendations
and the managed Up Next queue. All tracks are fictional fixtures from **Mochi
Demo Studio**; playback and provider responses are simulated. This is an interface
preview, not evidence of real-account Spotify playback or recommendation quality.

The card sits on a solid presentation backdrop because offscreen view
rendering does not include the window compositor's Liquid Glass material.
Animation timing is condensed for the preview. The mascot and card are rendered
from app code, with a presentation backdrop and captions around them.

Regenerate on macOS 26+ with the Xcode toolchain, from the repository root:

```bash
bash scripts/render-demo.sh
```

The renderer uses `scripts/ReadmeDemo.swift` and the existing intercepted-network
test support. It never reads `.env`, Keychain or personal preferences, starts a
backend, or sends requests to Spotify/Last.fm. It requires no Python packages or
additional media tools.
