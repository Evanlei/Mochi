def parse_intent(prompt: str):
    text = prompt.lower()

    if "no vocals" in text:
        return {"vocals": False}

    if "with vocals" in text:
        return {"vocals": True}

    return {"vocals": None}

