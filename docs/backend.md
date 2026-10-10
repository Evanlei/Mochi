# Local backend walkthrough

Mochi sends listening text from the native card to Python, interprets preferences, and independently ranks Last.fm candidates. Swift resolves recommendations to Spotify and starts confident matches. The backend stores Mochi feedback/context in SQLite and never receives Spotify credentials. See [the live discovery guide](music-discovery.md) for setup, constraints, persistence and evaluation. The examples below explain the original request boundary and explicit fictional demo mode (`MOCHI_CATALOG_MODE=sample`).

## What happens when you press Send

1. `MochiRequestModel.submit()` reads your text or the quick choice you clicked. It trims whitespace, marks the request as pending, and shows **Sending your request…**.
2. `MochiBackendClient.send()` converts `MochiListeningRequest` into JSON and sends a POST request to `http://127.0.0.1:8000/listening-request`.
3. FastAPI matches that address to `receive_listening_request()`. Pydantic checks that the JSON contains a text field named `prompt`, removes leading/trailing whitespace, and requires 1–500 characters afterward. Invalid input receives HTTP 422 before the route function runs.
4. `interpret_request()` in `backend/intent.py` checks explicit vocal, energy, and BPM constraints, including scoped negation and conflicts. If energy remains unspecified, the prepared local text model can compare the wording with reference descriptions. `SongSelector` filters the sample catalog by requirements and ranks eligible entries using the original text. The route includes preferences, optional clarification, and selection in `ListeningResponse`. FastAPI checks its format and converts it to JSON.
5. Swift checks for HTTP 200 and decodes the JSON into `MochiListeningResponse`. `CodingKeys` maps Python's `received_prompt` to Swift's `receivedPrompt`. The client also checks that Python echoed the submitted text.
6. The model adds the confirmed text to the session's summary and stores the selection. The card displays **Sample matches** with preferences and sample rows, or a clarification/empty-result message. Older responses without selection still display preference confirmation. It clears the submitted draft while preserving any new text you typed during the wait. Pending/new requests clear the old selection, and reset clears it too.

`/health` is a separate diagnostic route. Mochi does not call it before every request.

## API contract

`GET /health` returns HTTP 200:

```json
{"status": "ok"}
```

`POST /listening-request` accepts:

```json
{"prompt": "relaxing music for studying"}
```

It returns HTTP 200:

```json
{
  "received_prompt": "relaxing music for studying",
  "intent": {"vocals": null, "energy": "low", "bpm_min": null, "bpm_max": null},
  "clarification": null,
  "selection": {
    "catalog_kind": "fictional_sample",
    "method": "semantic",
    "tracks": [],
    "message": null
  }
}
```

The `tracks` array above is abbreviated; successful matches contain up to five entries with `id`, `title`, `artist`, nullable `bpm`, `vocals`, `energy`, `description`, and `score`. `method` is `semantic`, `lexical`, or `none`. The API docs show the full schema. Selection scores are ranking values, not probabilities. No-match and clarification responses contain an empty list and a message.

`intent.vocals` is `false` for instrumental requests or exclusions such as `no vocals` and `without lyrics`, `true` for requests for singing/vocals, and `null` if unspecified or conflicting. `null` represents Python's `None`: no single preference was established. Word boundaries prevent partial-word matches. Negation is scoped so `no vocals and upbeat` preserves upbeat energy. Swift decodes both the intent and the clarification.

`intent.energy` is `"low"`, `"high"`, or `null`. Explicit phrases such as calm, mellow, upbeat, or high energy take priority. Negated and conflicting energy constraints cannot be overwritten by the model. A prepared local model can infer an energy preference from broader wording, and abstains when similarity or the winning margin is too small. `clarification` contains a short question for conflicting preferences or an energy exclusion needing further detail.

`intent.bpm_min` and `intent.bpm_max` are inclusive numeric bounds, or `null` if unspecified. `90 BPM` produces equal bounds; `80–100 BPM` produces a range. BPM remains separate from energy. Ambiguous, unsupported, contradictory, or out-of-range tempo requests ask for clarification. See [sample song selection](song-selection.md) for the supported forms and filtering behavior.

Missing, non-text, blank, or overlong prompts receive HTTP 422. Length is measured in Python characters (Unicode code points); Swift checks Unicode scalar count to match it. Spaces between words remain intact. The browser testing page at `/docs` documents these formats and can send example requests without running Mochi.

## Waiting, failure, and cancellation

`async` and `await` let the model wait for the network without blocking the interface. `throws` lets the client report a failure, which the model handles in `catch`.

`isSending` controls the loading state and disables Send and quick choices. The model also rejects duplicate submissions, including repeated Return presses. Your draft stays available until success; a failed quick choice is copied into the input for retry. Requests time out after thirty seconds. Validation, unavailable-server, timeout, server-error, and unexpected-response messages are displayed in the card. Requests are not automatically retried.

The reset button cancels the stored `sendTask` and changes a request identifier. A late response from the old request cannot change a fresh conversation. Stopping the companion also cancels pending work. Closing the card merely hides it; a pending request can finish while hidden. Switching to Spotify search keeps the two flows independent.

## Running locally

```bash
cd /Users/evan/Documents/Mochi/backend
uv sync
uv run fastapi dev main.py
```

Keep this terminal running. Control-C stops the server; saved Python changes reload it. The `.venv` directory holds installed packages and is ignored by Git. `pyproject.toml` lists dependencies; `uv.lock` records their resolved versions so setup can be reproduced.

Those commands use the deterministic rules. To enable semantic matching, run `uv sync --extra semantic`, prepare the model with `uv run --extra semantic python ../scripts/prepare-intent-model.py`, and start with `uv run --extra semantic fastapi dev main.py`. Model files are already prepared on this workspace. See [request understanding](intent-understanding.md) for the model, evaluation, and offline behavior.

Python runs separately from the macOS app. Mochi currently does not start or package Python automatically. `Mochi/BackendTransport.plist` permits HTTP specifically to `127.0.0.1` through Apple's App Transport Security settings; Spotify continues to use HTTPS. The backend client uses an ephemeral session without persistent cookies or caching and refuses redirects.

## Next development step

Live discovery, independent ranking, conservative Spotify resolution, queue playback and first-party taste memory are now implemented. See [music discovery](music-discovery.md) for the current contract and source-validation limits. Next, configure the Last.fm key, manually judge real candidate rankings and verify live account playback. Reliable musical measurements and learned ranking remain future work.
