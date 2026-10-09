def parse_intent(prompt: str):
    text = prompt.lower()

    vocals = None
    if "no vocals" in text:
        vocals = False
    elif "with vocals" in text:
        vocals = True

    energy = None
    if "relaxing" in text:
        energy = "low"
    elif "energetic" in text:
        energy = "high"

    return {
        "vocals": vocals,
        "energy": energy
    }