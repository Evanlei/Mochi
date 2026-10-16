# Mochi compact studies

Open `index.html` directly. No build step, network dependency, API, authentication, or playback request is used.

## A — listening panel
300 × 200px idle. Modes remain visible, so the relationship between taste and discovery is easy to learn. Presets have their own quiet row. This takes more desktop space but exposes the product model immediately.

## B — composer first
300 × 150px idle. The current mode becomes a dropdown beside the secondary controls. The composer feels immediate and the silhouette stays smaller. The tradeoff is an extra click to compare modes. Labeled tooltips and accessible names keep favorites, reset, and dismissal discoverable.

Both expand to 300 × 340px for recommendations and 300 × 320px for artist editing. Results scroll within the fixed width. Favorite artists are unique, limited to three, and required for Familiar and Discover; Balanced is the default. Removing the last artist restores Balanced. Done commits the pending mode; Skip leaves the current mode unchanged unless there are no favorites.

## Review journeys
1. Choose a preset or type a request and press Enter. Cancel while loading, or inspect the five suggestions. Like/dislike a track and use its options to refine. The applied batch mode stays separate from the next-request selector.
2. Select Familiar or Discover before choosing favorites. Type an artist, choose a matching result or use Add for an exact name, then Done. To test lookup failure, choose Offline in the preview toolbar, open favorites, type an artist and press Add. Retry preserves the typed input and restores the local demo lookup.
3. Use the separate menu-bar player. Previous, play/pause and next only change local demonstration state. The disclosure contains track-link and API-setting previews. Discovery never offers automatic play or queue.

The preview toolbar is outside the product. Compare / Try A / Try B displays actual CSS size, and the toolbar demonstrates loading, offline, empty, dark desktop and solid-material states. Escape dismisses the nearest active layer. Reduced motion disables mascot and panel animation.

## Content and fidelity
All track and artist names are real; their recommendation relationship is illustrative demo data. No live fetching is claimed. Spotify and Last.fm actions show local handoff feedback rather than making external requests. No BPM, energy or vocals values are invented. Empty tempo results preserve the requested range.

The supplied Mochi SVG is embedded unchanged in geometry and colors, with preserved aspect ratio. Its full character group squashes and stretches together, including the attached hands; eyes blink independently. There is no ground shadow. Playback animation is optional and local. Pale sage tokens derive from the supplied mascot and SwiftUI material, with system typography appropriate to a native utility.

