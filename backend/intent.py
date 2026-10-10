"""Explicit constraints take priority; uncertain energy can use a local model."""

import re
import logging
import unicodedata
from dataclasses import dataclass, replace
from typing import Literal

VOCALS = re.compile(r"\b(?:vocals?|singing|singers?|lyrics|voices?)\b")
INSTRUMENTAL = re.compile(r"\b(?:instrumentals?|wordless)\b")
LOW_ENERGY = re.compile(r"\b(?:relax(?:ing|ed)?|calm(?:ing|er)?|mellow|chill|gentle|soothing|peaceful|laid[ -]back|low[ -]energy|downtempo)\b")
HIGH_ENERGY = re.compile(r"\b(?:energetic|upbeat|lively|high[ -]energy|hype|intense)\b")
VOCAL_CLAUSE = re.compile(r"\b(?:(?:no preference for|don't mind|dont mind|don't want|dont want|no|not|without|avoid|skip|exclude|nothing|never|with)\s+)?(?:vocals?|singing|singers?|lyrics|voices?|instrumentals?|wordless)\b")
NEGATORS = {"no", "not", "without", "avoid", "skip", "exclude", "nothing", "never", "don't", "dont"}
MODIFIERS = {"any", "more", "very", "too", "really", "much", "a", "bit", "of", "with", "the", "that", "something", "songs", "music", "tracks", "to", "be", "want", "do"}


@dataclass(frozen=True)
class IntentResult:
    vocals: bool | None = None
    energy: Literal["low", "high"] | None = None
    clarification: str | None = None
    energy_locked: bool = False
    bpm_min: float | None = None
    bpm_max: float | None = None

    def values(self):
        return {"vocals": self.vocals, "energy": self.energy}


def _tempo_preference(text):
    """Only explicit numbers constrain tempo; mood words never imply BPM."""
    unit = r"(?:bpm|beats per minute)\b"
    number = r"(\d+(?:\.\d+)?)"
    ranges = list(re.finditer(r"\b(?:(?:between|from)\s+)?" + number +
        r"\s*(?:-|to|and)\s*" + number + r"\s*" + unit, text))
    matches = [(match, float(match[1]), float(match[2])) for match in ranges]
    for match in re.finditer(r"\b" + number + r"\s*" + unit, text):
        if not any(start.start() <= match.start() < start.end() for start in ranges):
            matches.append((match, float(match[1]), float(match[1])))
    if not re.search(r"\b" + unit, text):
        return None, None, None
    question = "What BPM value or range would you like? Try 90 BPM or 80–100 BPM."
    if not matches:
        return None, None, question
    for match, lower, upper in matches:
        before = text[max(0, match.start() - 30):match.start()]
        if (not 20 <= lower <= upper <= 400 or _negated(text, match.start()) or
            re.search(r"(?:under|over|below|above|around|about|at least|at most|less than|more than)\s*$", before)):
            return None, None, question
    lower, upper = max(item[1] for item in matches), min(item[2] for item in matches)
    return (lower, upper, None) if lower <= upper else (None, None, question)


def _negated(text, start):
    # Stop at conjunctions/punctuation so "no vocals and upbeat" keeps upbeat.
    clause = re.split(r"[,;.!?]", text[:start])[-1]
    tokens = re.findall(r"[a-z]+(?:'[a-z]+)?", clause)
    count = 0
    for token in reversed(tokens[-8:]):
        if token in NEGATORS:
            count += 1
        elif token not in MODIFIERS:
            break
    return count % 2 == 1


def interpret_request(prompt, *, use_semantic=True, matcher=None):
    text = unicodedata.normalize("NFKC", prompt).casefold().replace("’", "'")
    text = text.replace("–", "-").replace("—", "-")
    vocal_values = set()
    for pattern, positive in ((VOCALS, True), (INSTRUMENTAL, False)):
        for match in pattern.finditer(text):
            before = text[max(0, match.start() - 35):match.start()]
            if re.search(r"(?:no preference (?:for|about)|don't mind|dont mind|don't care about|any preference for)\s*$", before):
                continue
            vocal_values.add(not positive if _negated(text, match.start()) else positive)
    if re.search(r"\beither\b.*(?:\b(?:vocals?|singing)\b.*\bor\b.*\binstrumental\b|\binstrumental\b.*\bor\b.*\b(?:vocals?|singing)\b)", text):
        vocal_values.clear()

    positive_energy, excluded_energy = set(), set()
    for pattern, value in ((LOW_ENERGY, "low"), (HIGH_ENERGY, "high")):
        for match in pattern.finditer(text):
            (excluded_energy if _negated(text, match.start()) else positive_energy).add(value)

    vocal_conflict = len(vocal_values) > 1
    energy_conflict = len(positive_energy) > 1 or bool(positive_energy & excluded_energy)
    vocals = next(iter(vocal_values)) if len(vocal_values) == 1 else None
    energy = next(iter(positive_energy)) if len(positive_energy) == 1 and not energy_conflict else None
    questions = []
    if vocal_conflict:
        questions.append("Would you like vocals or instrumental music?")
    if energy_conflict or (excluded_energy and not positive_energy):
        questions.append("What energy level would you like?")
    bpm_min, bpm_max, tempo_question = _tempo_preference(text)
    if tempo_question:
        questions.append(tempo_question)
    result = IntentResult(vocals, energy, " ".join(questions) or None,
                          bool(positive_energy or excluded_energy), bpm_min, bpm_max)

    # Vocal constraints are handled separately and can distort energy similarity.
    energy_text = " ".join(VOCAL_CLAUSE.sub(" ", text).split()).strip(" ,.;!?")
    if use_semantic and not result.energy_locked and len(energy_text.split()) >= 2:
        if matcher is None:
            from semantic import get_matcher
            matcher = get_matcher()
        if matcher is not None:
            try:
                result = replace(result, energy=matcher.predict(energy_text))
            except Exception:
                # A model failure must not invalidate explicit vocal constraints.
                logging.getLogger(__name__).warning("Local intent inference failed; using explicit constraints")
    return result


def parse_intent(prompt: str):
    return interpret_request(prompt).values()
