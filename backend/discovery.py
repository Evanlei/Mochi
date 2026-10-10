"""Small, inspectable discovery vocabulary; the model never invents song names."""

import re

from music import CatalogTrack, normalized
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


async def discover(prompt, lastfm, *, favorites=()):
    tags = discovery_tags(prompt)
    if not tags and not favorites:
        return [], ["Add a genre or instrument, such as jazz, piano, indie, or electronic."]
    tracks, warnings = {}, []
    pools = []
    for tag in tags:
        try: pools.append(await lastfm.top_tracks(tag))
        except ProviderError as error: warnings.append(str(error))
    if favorites:
        try: pools.append(await lastfm.similar(favorites[-1]))
        except ProviderError as error: warnings.append(str(error))
    for pool in pools:
        for track in pool:
            if track.id in tracks:
                previous = tracks[track.id]
                merged = tuple(dict.fromkeys(previous.tags + track.tags))
                tracks[track.id] = previous.model_copy(update={"tags": merged, "description": "Community tags: " + ", ".join(merged)})
            else:
                tracks[track.id] = track
    # Bound per-request memory and provider work. Provider order is retained only
    # as the acquisition baseline; selection ranks by the user's full request.
    return list(tracks.values())[:65], list(dict.fromkeys(warnings))
