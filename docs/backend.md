# Local backend walkthrough

Mochi can now send listening text from the native card to Python and display confirmation. This establishes the connection that the recommendation system will eventually use. The current backend validates and echoes text and detects vocal and energy preferences from explicit constraints and optional local semantic matching. It does not choose songs, start music, save requests to a database, or receive Spotify credentials.

## What happens when you press Send

1. `MochiRequestModel.submit()` reads your text or the quick choice you clicked. It trims whitespace, marks the request as pending, and shows **Sending your request…**.
2. `MochiBackendClient.send()` converts `MochiListeningRequest` into JSON and sends a POST request to `http://127.0.0.1:8000/listening-request`.
3. FastAPI matches that address to `receive_listening_request()`. Pydantic checks that the JSON contains a text field named `prompt`, removes leading/trailing whitespace, and requires 1–500 characters afterward. Invalid input receives HTTP 422 before the route function runs.
4. `interpret_request()` in `backend/intent.py` checks explicit vocal and energy constraints, including scoped negation and conflicts. If energy remains unspecified, the prepared local text model can compare the wording with reference descriptions. The route includes both preferences and an optional clarification in `ListeningResponse`. FastAPI checks its format and converts it to JSON.
5. Swift checks for HTTP 200 and decodes the JSON into `MochiListeningResponse`. `CodingKeys` maps Python's `received_prompt` to Swift's `receivedPrompt`. The client also checks that Python echoed the submitted text.
6. The model adds the confirmed text to the session's summary and displays the detected preferences or a clarification question. If no preference is detected, it displays **Request received. Recommendations are coming next.** It clears the submitted draft while preserving any new text you typed during the wait.

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
{"received_prompt": "relaxing music for studying", "intent": {"vocals": null, "energy": "low"}, "clarification": null}
```

`intent.vocals` is `false` for instrumental requests or exclusions such as `no vocals` and `without lyrics`, `true` for requests for singing/vocals, and `null` if unspecified or conflicting. `null` represents Python's `None`: no single preference was established. Word boundaries prevent partial-word matches. Negation is scoped so `no vocals and upbeat` preserves upbeat energy. Swift decodes both the intent and the clarification.

`intent.energy` is `"low"`, `"high"`, or `null`. Explicit phrases such as calm, mellow, upbeat, or high energy take priority. Negated and conflicting energy constraints cannot be overwritten by the model. A prepared local model can infer an energy preference from broader wording, and abstains when similarity or the winning margin is too small. `clarification` contains a short question for conflicting preferences or an energy exclusion needing further detail.

Missing, non-text, blank, or overlong prompts receive HTTP 422. Length is measured in Python characters (Unicode code points); Swift checks Unicode scalar count to match it. Spaces between words remain intact. The browser testing page at `/docs` documents these formats and can send example requests without running Mochi.

## Waiting, failure, and cancellation

`async` and `await` let the model wait for the network without blocking the interface. `throws` lets the client report a failure, which the model handles in `catch`.

`isSending` controls the loading state and disables Send and quick choices. The model also rejects duplicate submissions, including repeated Return presses. Your draft stays available until success; a failed quick choice is copied into the input for retry. Requests time out after ten seconds. Validation, unavailable-server, timeout, server-error, and unexpected-response messages are displayed in the card. Requests are not automatically retried.

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

Replace the echo operation with a recommendation pipeline backed by an appropriately licensed independent music dataset. Request context, candidate retrieval, ranking, feedback persistence, Spotify resolution, and queue playback are future work. The current session summary is local state; Python receives only the text submitted in each request.
