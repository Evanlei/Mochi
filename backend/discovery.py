"""Small, inspectable discovery vocabulary; the model never invents song names."""

import re
import asyncio
from itertools import zip_longest

from music import CatalogTrack, DiscoveryMode, normalized
from providers import ProviderError

# These are retrieval hints, not assertions of a recording's measured features.
TAG_CUES = {
    "piano": ("piano", "keys", "keyboard"),
    "acoustic": ("acoustic", "guitar", "unplugged"),
    "jazz": ("jazz", "sax", "saxophone"),
    "classical": ("classical", "orchestra", "orchestral"),
    "lo-fi": ("lo fi", "lofi", "lo-fi"),
    "ambient": ("ambient", "dreamy", "ethereal", "sleep", "sleeping"),
    "chillout": ("chill", "calm", "relaxing", "relax", "unwind", "mellow", "gentle"),
    "electronic": ("electronic", "edm", "synth", "techno", "coding"),
    "hip-hop": ("hip hop", "hip-hop", "rap", "rapping"),
    "rnb": ("rnb", "r&b", "rhythm and blues"),
    "rock": ("rock", "guitar riffs"),
    "metal": ("metal", "heavy metal"),
    "pop": ("pop",),
    "indie": ("indie",),
    "folk": ("folk",),
    "dance": ("dance", "party", "gym", "workout", "hype", "energetic", "upbeat"),
    "instrumental": ("instrumental", "instrumentals", "wordless", "no vocals", "without lyrics", "without vocals"),
    "study": ("study", "studying", "focus", "concentrate", "homework"),
    "sad": ("sad", "melancholy", "melancholic", "heartbreak"),
}


def discovery_tags(prompt):
    text = normalized(prompt)
    hits = []
    for tag, cues in TAG_CUES.items():
        positions = [match.start() for cue in cues if (match := re.search(r"\b" + re.escape(normalized(cue)) + r"\b", text))
            and not re.search(r"\b(?:no|not|avoid|without|skip)\s*$", text[:match.start()])]
        if positions:
            hits.append((min(positions), tag))
    # No arbitrary genre silently becomes the meaning of an unknown request.
    if not hits and text in {"surprise me", "anything", "any music", "music"}:
        return ["pop", "indie"]
    return [tag for _, tag in sorted(hits)[:2]]


def is_broad_request(prompt):
    return normalized(prompt) in {"surprise me", "anything", "any music", "music", "my favorites", "play my favorites"}


async def discover(prompt, lastfm, *, favorites=(), seed=None, artists=(), mode=DiscoveryMode.BALANCED):
    mode = DiscoveryMode(mode)
    if seed is not None:
        # An explicit choice replaces generic pools. Do not substitute unrelated
        # popular tracks when this recording has no similar-track coverage.
        try:
            pool = await lastfm.similar(seed, limit=50)
            return list({track.id: track for track in pool if track.id != seed.id}.values())[:50], []
        except ProviderError as error:
            return [], [str(error)]
    tags = discovery_tags(prompt)
    if artists and is_broad_request(prompt):
        tags = []  # The user's artists provide the starting point for this session.
    if not tags and not favorites and not artists:
        return [], ["Add a genre or instrument, such as jazz, piano, indie, or electronic."]
    tracks, warnings = {}, []
    pools = []
    artist_limit, neighbor_limit, tag_limit = {
        DiscoveryMode.FAMILIAR: (20, 1, 8),
        DiscoveryMode.BALANCED: (10, 2, 15),
        DiscoveryMode.DISCOVER: (5, 3, 15),
    }[mode]
    async def acquire(call):
        try: pools.append(await call)
        except ProviderError as error: warnings.append(str(error))

    try:
        # Reserve part of the service's 20-second budget for recording tags.
        # A timeout preserves already completed pools rather than losing them.
        async with asyncio.timeout(12):
            for artist in artists[:3]:
                await acquire(lastfm.artist_tracks(artist, limit=artist_limit))
            for tag in tags:
                await acquire(lastfm.top_tracks(tag, limit=tag_limit if artists else 25))
            related, neighbors, chosen = [], [], {normalized(name) for name in artists}
            for artist in artists[:min(2, neighbor_limit)]:
                try: names = await lastfm.similar_artists(artist, limit=3)
                except ProviderError as error:
                    warnings.append(str(error)); continue
                neighbors.append(names)
            for group in zip_longest(*neighbors):
                for name in group:
                    if name is not None and normalized(name) not in chosen:
                        related.append(name); chosen.add(normalized(name))
                        if len(related) == neighbor_limit: break
                if len(related) == neighbor_limit: break
            for name in related:
                await acquire(lastfm.artist_tracks(name, limit=10))
            if favorites:
                await acquire(lastfm.similar(favorites[-1]))
    except TimeoutError:
        warnings.append("Some discovery sources took too long; using the completed pools.")
    # Give each pool a turn so favorites/related artists/session tags all have
    # room inside the 65-recording cap. Never attach an artist's genre to a song.
    for group in zip_longest(*pools):
        for track in group:
            if track is None: continue
            if track.id in tracks:
                previous = tracks[track.id]
                merged = tuple(dict.fromkeys(previous.tags + track.tags))
                tracks[track.id] = previous.model_copy(update={"tags": merged, "description": "Community tags: " + ", ".join(merged)})
            else:
                tracks[track.id] = track
    # Bound per-request memory and provider work. Provider order is retained only
    # as the acquisition baseline; selection ranks by the user's full request.
    return list(tracks.values())[:65], list(dict.fromkeys(warnings))
