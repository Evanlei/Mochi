# Mochi Product and Engineering Specification

> **Status:** Living source of truth  
> **Product:** Mochi — Context-Aware macOS Music Companion  
> **Primary platform:** macOS  
> **Primary objective:** Build a technically credible software engineering project while developing the author's independent engineering ability.

## Current implementation decision — October 10, 2026

The sections below retain the long-term product vision. This decision defines the current recommendation V1 and takes precedence over the earlier planned dataset size, unimplemented features and first-session instructions.

- **Product:** personal desktop DJ; describe a session, discover real music, personalize ordering and play through Spotify. Keep the native compact interface and local FastAPI/SQLite architecture.
- **Discovery:** Last.fm tag pools are the primary independent source. Up to two prompt-derived tags plus a fresh remembered-favorite seed acquire at most 65 candidates; at most 12 receive detail lookups. This reaches beyond cached songs but does not guarantee every Spotify recording or the newest releases.
- **Ranking:** the existing semantic text model (lexical fallback) uses independent Last.fm text and inspected tag cues, followed by transparent like/artist-affinity/repetition adjustments. No learned ranking model, FAISS index or cloud infrastructure is introduced without measured need.
- **Constraints:** BPM, vocals and energy are nullable in Python and Swift. Unknown values cannot meet strict requirements. BPM ranges are never silently widened. Mood adjectives guide live relevance; explicit low/high energy demands verified data. Reliable vocal/energy measurements are currently unavailable.
- **Enrichment:** ReccoBeats is experimental and off by default. Promote only validated tempo tied to a confidently identified recording; keep its Spotify-derived basic metadata out of model input. Three live probes found one estimated-tempo match and two ambiguous recordings, without establishing general coverage or tempo accuracy.
- **Spotify:** the native client performs deterministic artist/title/version/ISRC/duration matching, rejects uncertain versions and plays the confirmed subset of up to five ranked recordings. Spotify payloads stay out of the backend/model. Playback and menu controls share serialization and cancellation safeguards.
- **Taste:** persist first-party Mochi likes, dislikes, selection/replay commands and recommendation context separately from provider caches. Dislikes exclude tracks; bounded artist affinity and repetition penalties affect later ranking. No Spotify history ingestion, automatic skip interpretation, inferred completed listens or multi-account profiles. Similar-track seeds depend on fresh canonical provider metadata.
- **Storage:** a physical-page-bounded 40 MB SQLite provider cache honors HTTP freshness headers. No persisted embeddings; at most eight candidate catalogs in memory. One optional evaluation capture is bounded at 2 MB. Taste stores prompt/context and opaque IDs separately, with 30-day context retention and at most 10,000 feedback events.
- **Development fixtures:** fictional music is available only through explicit `MOCHI_CATALOG_MODE=sample`, labeled in the interface and excluded from automatic Spotify playback. Missing live credentials show setup instructions, never a fictional fallback.
- **Verification:** provider/cache/strict-filter/feedback checks, independent native recording-resolution and partial-playback checks, cancellation/stale-response checks, UI accessibility/render checks and a manually graded ranking-snapshot tool. Fictional fixture scores are not live quality evidence.
- **Release:** private noncommercial hobby testing only. Spotify development mode currently limits authenticated users to five; broader access and Last.fm public-use permission must be resolved before distribution. Last.fm's storage allowance is 100 MB, including derived provider data.

Implemented source adapters, ranking, taste persistence, Swift resolution/playback and documentation are committed in separate increments. Last.fm live validation remains pending because no API key is configured. Real-account recommendation playback and live ranking judgments must follow before inviting testers.

Setup, flow, current API contracts, failure behavior, evidence and provider references: [music discovery](docs/music-discovery.md). Provider decisions follow [Last.fm's terms](https://www.last.fm/api/tos), [ReccoBeats's terms](https://reccobeats.com/docs/documentation/terms-of-service), [Spotify's developer policy](https://developer.spotify.com/policy) and [quota rules](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## 1. Product Summary

Mochi is a native macOS music companion that lets a user describe what they want to hear in natural language and automatically plays personalized music through Spotify.

Example requests:

- “Dreamy late-night coding music, but keep me awake.”
- “Gym music, but I'm tired of the songs I've been replaying.”
- “Something slightly sad for a night walk, but not depressing.”
- “Give me something like what I listened to while studying last Tuesday, but more energetic.”

Mochi is not an LLM-powered song list generator or an “AI Spotify wrapper.” Its technical centerpiece is a recommendation system that combines:

1. Natural-language intent understanding
2. Semantic candidate retrieval
3. User preference modeling
4. Personalized ranking
5. Implicit feedback
6. Spotify track resolution and playback

Spotify serves primarily as the music catalog and playback provider. Mochi owns the recommendation intelligence.

## 2. Product Vision

Mochi should eventually live as a small animated character or menu-bar application on macOS.

A user opens the companion and enters a lightweight prompt:

```text
        /\_/\
       ( o.o )
        > ^ <

┌─────────────────────────────┐
│ What do you want to hear?   │
│                             │
│ > dreamy late-night coding  │
│   but keep me awake         │
└─────────────────────────────┘
```

During playback, Mochi presents the current track and essential controls:

```text
        /\_/\
       ( ^.^ )  ♫
        > ^ <

      Now Playing

     Nights
     Frank Ocean

 ━━━━━━━━━●━━━━━━━━

      ◀   ❚❚   ▶
```

The character may react visually to playback state and musical context. This companion experience is important for differentiation and demo appeal, but the recommendation system and engineering architecture remain the technical core.

## 3. Product Positioning

Mochi must not use the following architecture:

```text
Prompt
  ↓
LLM
  ↓
LLM invents songs
  ↓
Spotify
```

The intended flow is:

```text
Natural-language request
          ↓
Intent representation
          ↓
Candidate retrieval
          ↓
Personalized ranking
          ↓
Spotify resolution
          ↓
Playback
```

The project is intended primarily to strengthen a resume for software engineering internships. Machine learning is an important subsystem, but the finished product should also demonstrate:

- Native macOS development
- Swift and SwiftUI
- Python and backend APIs
- REST and OAuth
- Asynchronous programming
- Third-party API integration
- Persistence
- Recommendation systems and vector search
- ML inference and evaluation
- Caching
- State synchronization
- Testing and error handling
- System design

## 4. Goals and Non-Goals

### 4.1 Goals

- Provide a native, lightweight macOS interaction model.
- Translate subjective natural-language requests into relevant music candidates.
- Personalize rankings using explicit and implicit user preferences.
- Resolve independently recommended tracks to reliable Spotify catalog matches.
- Control Spotify playback and synchronize playback state with the native client.
- Establish measurable baselines before introducing learned ranking.
- Build a production-quality project whose major decisions the developer can explain and defend.
- Use the real project as the curriculum for learning Swift, SwiftUI, Python, backend engineering, recommendation systems, and ML.

### 4.2 Non-Goals

- Asking an LLM to invent a playlist.
- Streaming or hosting copyrighted audio.
- Training recommendation models directly on Spotify data without confirming policy and licensing compatibility.
- Prematurely introducing microservices, Kubernetes, Redis, cloud infrastructure, neural networks, or other unjustified complexity.
- Generating the entire repository without the developer understanding and implementing important code paths.
- Building disconnected tutorial applications that will later be discarded.

## 5. High-Level Architecture

```text
                    macOS Client
                  Swift + SwiftUI
                         │
           ┌─────────────┴─────────────┐
           │                           │
     Companion UI               Playback State
           │                           │
           └─────────────┬─────────────┘
                         │
                       REST
                         │
                         ▼
                  Python Backend
                     FastAPI
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       ▼                 ▼                 ▼
 Recommendation      User/Profile       Persistence
    Service            Service
       │
       ▼
 Candidate Retrieval
       │
       ▼
 Personalized Ranking
       │
       ▼
 Recommended Tracks
       │
       ▼
 Spotify Resolver
       │
       ▼
 Spotify Playback
```

Service boundaries may evolve when implementation reveals a concrete need. Mochi should remain a modular monolith unless scale or operational constraints justify additional services.

## 6. End-to-End Data Flow

```text
User
 │ natural-language request
 ▼
SwiftUI interface
 │ HTTP request
 ▼
FastAPI backend
 │
 ▼
Intent representation / embedding
 │
 ▼
Vector candidate retrieval
 │
 ▼
Personalized ranking
 │
 ▼
Ranked canonical tracks
 │
 ▼
Spotify entity resolution
 │
 ▼
Playable Spotify URIs
 │
 ▼
Spotify playback
 │
 ▼
Playback events
 │
 ▼
SwiftUI state synchronization
 │
 ▼
User behavior
 │
 ▼
Feedback persistence
 │
 ▼
Ranking data / learning
```

For every boundary, the implementation and documentation should identify:

- The data being transferred
- Its format
- The component that owns the operation
- Possible failure modes
- Error-handling behavior
- The reason the boundary exists

## 7. Recommendation System

Mochi uses a two-stage recommendation pipeline.

### 7.1 Stage 1 — Candidate Retrieval

The backend converts the user's natural-language request into a semantic representation, then retrieves approximately 100–500 contextually relevant candidate tracks.

```text
Prompt embedding
       ↓
Similarity search
       ↓
Candidate tracks
```

Likely techniques include:

- Text embeddings
- Cosine similarity
- Vector search
- FAISS or an equivalent nearest-neighbor index

The music dataset and track representation must be researched and justified. Spotify data must not be assumed suitable for model training; current Spotify API terms and developer policies must be verified before implementation.

Candidate retrieval answers:

> Which tracks plausibly satisfy this request?

It does not decide which candidates are best for the particular user.

### 7.2 Stage 2 — Personalized Ranking

The ranking stage orders retrieved candidates for the current user and context.

Potential features include:

- Semantic similarity
- Artist affinity
- Genre affinity
- Track affinity
- Recent play history
- Play count
- Skip count
- Explicit likes or dislikes
- Previous recommendation acceptance
- Time of day
- Prompt context
- Novelty
- Recent overplay

The initial implementation must use a transparent heuristic baseline:

```text
score =
    semantic_match
  + user_preference
  + novelty
  - recent_overplay
```

This heuristic is a measurable baseline, not a disguised final ML system.

### 7.3 Learned Ranking

Once useful feedback data exists, Mochi may replace or augment the heuristic with a learned model.

A possible target is:

```text
P(user accepts or likes track | track, user, context)
```

Candidate approaches include:

- Logistic regression
- Gradient-boosted trees
- Learning-to-rank methods

A neural network should be introduced only if the data and measured limitations justify it.

The learned model must be evaluated against the heuristic baseline. Relevant metrics include:

- Precision@K
- Recall@K
- NDCG@K
- Acceptance rate
- Skip rate
- Replay rate

## 8. Feedback Loop

Mochi should eventually learn from user behavior:

```text
Recommendation
      ↓
Playback
      ↓
User behavior
  ↓    ↓    ↓
skip  like  replay
  └────┼────┘
       ↓
Feedback store
       ↓
Ranking training and evaluation
```

Potential positive signals:

- Track played substantially
- Explicit like
- Replay
- Saved track
- Request for similar music

Potential negative signals:

- Immediate skip
- Repeated skips of similar tracks
- Explicit dislike

A skip must not automatically be treated as a strong dislike. It may instead reflect context mismatch, recent overplay, or a momentary preference for something different. Feedback records should preserve enough context to distinguish these interpretations later.

## 9. Taste Memory

Taste Memory is an advanced differentiating feature. Mochi associates prior listening contexts with recommendations and observed behavior.

Examples:

- “Give me something like what I listened to while studying last Tuesday.”
- “I liked that late-night NYC playlist you made. Make another one.”

Stored associations may include:

- Original prompt and normalized context
- Recommended tracks
- Tracks actually played
- Feedback
- Timestamp and environmental context

Taste Memory should help Mochi learn the individual user's meaning for subjective concepts such as “late night,” “studying,” “relaxing,” “gym,” “nostalgic,” and “energetic.”

This is not required for the initial release.

## 10. Spotify Integration

### 10.1 Responsibility Boundary

Mochi determines what should be played. Spotify determines how that music is found in its catalog and played through the user's account.

```text
Mochi recommendation engine
          ↓
Canonical track + artist
          ↓
Spotify resolver
          ↓
Spotify URI
          ↓
Spotify playback
```

### 10.2 Track Resolution

Tracks recommended from an independent dataset must be resolved against Spotify.

Preferred resolution strategy:

```text
Recommended track
       │
       ▼
ISRC available?
   /         \
 yes          no
  ↓            ↓
ISRC lookup   title + artist search
  │            │
  │            ▼
  │        fuzzy matching
  │            │
  └──────┬─────┘
         ▼
    Spotify URI
```

The resolver must not blindly choose the first search result. Matching may consider:

- ISRC
- Track-title similarity
- Artist similarity
- Duration
- Album
- Release metadata
- Version markers such as live, remastered, acoustic, or cover

Entity resolution is a distinct engineering subsystem whose accuracy should be tested independently from recommendation relevance.

### 10.3 Missing Tracks

A failed or low-confidence resolution must not fail the recommendation request.

```text
Candidate
    ↓
Spotify lookup
    ↓
Confident match?
   /       \
 yes        no
  ↓          ↓
queue      discard
             ↓
        next candidate
```

The recommendation engine should return more candidates than the final queue requires. For example:

```text
Rank 50 candidates
        ↓
Resolve against Spotify
        ↓
Collect first 20 confident matches
        ↓
Play available queue
```

The API should support partial success when fewer than the requested number of tracks resolve.

### 10.4 Playback

Spotify remains responsible for audio playback. Mochi should eventually support:

- Previous
- Play
- Pause
- Next
- Queue management
- Seek
- Current track
- Playback state synchronization

Before implementation, current official Spotify documentation must be checked for authentication requirements, endpoint availability, Premium requirements, rate limits, and developer-policy constraints. Critical architecture must not depend on an unverified API capability.

## 11. Technology Stack

### 11.1 Native Client

- Swift
- SwiftUI
- Native macOS APIs

### 11.2 Backend

- Python
- FastAPI
- REST/JSON API contracts

### 11.3 Recommendation and ML

Likely initial tools:

- Python
- NumPy
- scikit-learn
- FAISS or an equivalent
- A justified embedding model

PyTorch should be introduced only if a real requirement emerges.

### 11.4 Persistence

- SQLite initially
- PostgreSQL only if application requirements later justify it

Infrastructure must not be introduced solely for resume keywords.

## 12. Architecture and Engineering Principles

### 12.1 Separate Concerns

UI, authentication, networking, persistence, recommendation logic, Spotify resolution, and playback state must not accumulate in one SwiftUI view or backend module. Introduce boundaries when responsibilities become meaningfully distinct, without prematurely creating abstraction layers.

### 12.2 Build Baselines First

```text
Heuristic baseline
       ↓
Measure
       ↓
Learned model
       ↓
Measure
       ↓
Compare
```

### 12.3 Prefer Justified Complexity

Every technology and abstraction must answer:

> What concrete problem does this solve?

### 12.4 Measure Improvements

Where possible, record and compare:

- Recommendation relevance
- Ranking improvement
- Retrieval and API latency
- Cache hit rate
- Entity-resolution accuracy
- Skip, acceptance, and replay rates

### 12.5 Error Handling

Expected failures should be represented explicitly, including:

- Network unavailability
- Authentication denial or expiration
- Spotify rate limits
- Spotify catalog mismatch
- Backend unavailability
- Partial queue resolution
- Empty retrieval results
- Corrupt or unavailable persistence
- Playback state drift

User-facing errors should be actionable, while internal logs should preserve diagnostic context without exposing secrets.

### 12.6 Security and Privacy

- Do not commit credentials or tokens.
- Store client-side secrets and tokens using appropriate macOS security facilities.
- Do not embed credentials that cannot safely exist in a distributed client.
- Request only required OAuth scopes.
- Document what listening and feedback data is stored.
- Verify provider terms before collecting or using data for training.
- Avoid logging access tokens, refresh tokens, or sensitive user data.

### 12.7 Testing

Testing should be added in proportion to risk and include, as appropriate:

- Swift unit tests using Swift Testing
- macOS UI tests using XCUIAutomation
- Python unit and integration tests
- API contract tests
- Track-resolution fixture tests
- Ranking and evaluation tests
- Failure-path tests for authentication and networking

## 13. Development Phases

### Phase 1 — Native macOS Shell

Build the actual Mochi macOS application while learning Swift and SwiftUI in context.

Relevant concepts:

- Swift syntax
- Structs and classes
- Protocols where relevant
- Optionals
- Closures
- SwiftUI views
- State and bindings
- Observable state
- Events
- Menu-bar behavior
- Window management

**Exit criterion:** A minimal native Mochi interface exists, runs on macOS, and contains a meaningful state-driven interaction.

### Phase 2 — Spotify Integration

Implement:

- Spotify authentication
- OAuth flow
- Secure token storage
- Token refresh if applicable
- Track search and resolution
- Playback controls
- Playback state

**Exit criterion:** Mochi can control Spotify independently of the Spotify UI.

### Phase 3 — Python Backend

Implement the FastAPI backend, including initial API contracts, recommendation request boundaries, data access, and appropriate Spotify abstractions.

**Exit criterion:** The Swift client communicates cleanly and asynchronously with the Python backend.

### Phase 4 — Recommendation V1

Acquire and prepare an appropriate music dataset, then implement:

```text
Natural-language prompt
        ↓
Embedding
        ↓
Candidate retrieval
        ↓
Similarity ranking
        ↓
Canonical tracks
```

**Exit criterion:** Mochi independently produces contextually relevant music candidates.

### Phase 5 — Personalization

Combine semantic relevance with user preference, novelty, and recent-overplay penalties.

**Exit criterion:** Two users making the same request can receive different results based on their histories.

### Phase 6 — Feedback Collection

Persist recommendations, playback, skips, likes, replays, prompts, and relevant context.

**Exit criterion:** Mochi collects sufficiently structured data for later evaluation and model training.

### Phase 7 — ML Ranking

Train and evaluate a learned ranking model against the heuristic baseline.

**Exit criterion:** The comparison is reproducible and demonstrates whether the model materially improves personalization.

### Phase 8 — Companion UX

Improve the native experience with:

- Animated companion
- Prompt interface
- Album artwork
- Playback controls
- State animations
- Menu-bar behavior
- Compact floating interface

**Exit criterion:** Mochi is memorable, polished, and easy to demonstrate.

### Phase 9 — Engineering Quality

Add justified improvements such as:

- Caching
- Robust error handling
- Structured logging
- Tests
- Concurrency safeguards
- Rate-limit handling
- Secure configuration
- Persistence migrations
- Packaging

**Exit criterion:** Prototype code has been hardened into a credible engineered product.

### Phase 10 — Evaluation, Documentation, and Resume

Produce:

- Architecture documentation
- Setup instructions
- Technical diagrams
- Recommendation evaluation
- Demo video or GIF
- Screenshots
- Evidence-backed resume bullets

**Exit criterion:** Documentation accurately describes implemented functionality and measured results.

## 14. Scope and Milestones

Estimated full-project scope: **50–75 focused hours**, targeting approximately **60 hours**.

| Area | Estimated Time |
|---|---:|
| Swift/SwiftUI shell | 5–7 h |
| Spotify integration | 7–10 h |
| FastAPI backend | 4–6 h |
| Semantic retrieval | 7–10 h |
| Personalization | 6–8 h |
| ML ranking and evaluation | 8–12 h |
| Companion UI and animation | 6–10 h |
| Testing, polish, and packaging | 7–12 h |

These are planning estimates, not deadlines.

### Resume-Ready Milestone

A likely resume-ready milestone occurs after approximately **25–35 focused hours**, when this path works end-to-end:

```text
Natural-language request
          ↓
Backend intent processing
          ↓
Semantic retrieval
          ↓
Personalized ranking
          ↓
Spotify resolution
          ↓
Spotify playback
```

Resume claims must describe only functionality that has actually been implemented and measured.

## 15. Learning and Coding Ownership

Mochi has two equally important outputs:

1. A technically strong, production-quality software engineering project.
2. A developer who can independently understand, design, implement, debug, extend, and explain it.

The second output must not be sacrificed for implementation speed.

The developer has stronger experience in Java and C, is learning Python, and is new to Swift and SwiftUI. Learning must remain project-driven rather than becoming a detached sequence of beginner exercises.

### 15.1 Teaching Cycle

For each substantial component:

```text
What are we building?
        ↓
Why does it exist?
        ↓
Which concepts are required?
        ↓
Learn those concepts
        ↓
Review relevant APIs and syntax
        ↓
Developer designs or implements
        ↓
Run and observe
        ↓
Debug together
        ↓
Review and refactor
        ↓
Discuss tradeoffs
```

### 15.2 Developer Ownership

For important code, prefer:

```text
Explanation
    ↓
Small specification
    ↓
Developer attempt
    ↓
Review
    ↓
Debug
    ↓
Refactor
```

Boilerplate may be accelerated, but the developer must understand major architecture and code paths.

When blocked, assistance should escalate progressively:

1. Conceptual hint
2. Relevant API or data structure
3. Pseudocode
4. Partial implementation
5. Complete implementation with detailed walkthrough

### 15.3 Required Conceptual Depth

Teaching must include the underlying engineering ideas, not only syntax.

Examples:

- **SwiftUI state:** declarative UI, value semantics, state ownership, invalidation, bindings, observable models, and lifecycle.
- **OAuth:** authorization versus authentication, authorization codes, access and refresh tokens, scopes, redirect URIs, secret placement, failure modes, and production handling.
- **Semantic retrieval:** embeddings, vector spaces, cosine similarity, nearest-neighbor search, brute-force cost, vector indexes, and retrieval versus ranking.
- **Ranking:** feature design, bias, feedback ambiguity, baseline construction, offline metrics, and model comparison.
- **Async operations:** ownership, cancellation, error propagation, UI synchronization, and race conditions.

### 15.4 Engineering Questions

Development should regularly exercise reasoning with questions such as:

- Where should this state live?
- What happens if this request fails?
- Why should this secret not live in the Swift client?
- What is the runtime of this retrieval approach?
- How should five Spotify results with the same title be compared?
- Should this operation be synchronous?
- What should the API return if only 14 of 20 tracks resolve?

These questions should support real design decisions rather than trivia.

### 15.5 Code Review Standard

Developer-written code should be reviewed for:

- Correctness
- Architecture
- Readability and naming
- Separation of concerns
- Error handling
- Complexity
- Maintainability
- Testing
- Relevant performance characteristics

Code is not complete merely because it works once.

### 15.6 Debugging Method

When appropriate, use a systematic process:

```text
Observe behavior
      ↓
Form a hypothesis
      ↓
Inspect state and logs
      ↓
Isolate the component
      ↓
Test the hypothesis
      ↓
Find the root cause
      ↓
Fix
      ↓
Verify
```

The developer should increasingly perform these steps independently.

### 15.7 Interview Standard

For every major resume claim, the developer should be able to answer:

- Why was it built this way?
- Which alternatives were considered?
- What was difficult?
- What failed?
- How does it work end-to-end?
- What would break at larger scale?
- How was success measured?
- What would change in a rebuild?
- Which parts did the developer personally implement?

If those questions cannot be answered, revisit the component before featuring it prominently.

## 16. Assistant Working Rules

When assisting inside this repository:

- Do not silently implement major features.
- Explain important unfamiliar concepts before implementation.
- Let the developer implement substantive code after receiving a clear specification.
- Prefer reviewing and modifying developer code over replacing whole files.
- Provide direct help for incidental syntax, API quirks, boilerplate, and environment setup.
- Preserve productive struggle without creating artificial struggle.
- Explain new service layers, protocols, repositories, state models, caches, databases, and concurrency mechanisms by the concrete problem they solve.
- Establish correct baselines before optimizing.
- Challenge major architectural decisions constructively when evidence suggests a better direction.
- Keep each session moving the real Mochi repository toward the product.

The desired progression is from guided implementation toward independent design and code review.

## 17. First Development Session

The immediate objective is:

> Create the native macOS Mochi application shell using Swift and SwiftUI.

Do not begin with a generic Swift course and do not generate the completed application.

The session should answer:

1. What files did Xcode create?
2. What is the Swift application entry point?
3. What is a SwiftUI `View`?
4. What does declarative UI mean?
5. How does SwiftUI decide when to update a view?
6. What is state?
7. How can the first meaningful Mochi interaction work?

The target repository progression is:

```text
Mochi repository
       ↓
Native macOS target
       ↓
SwiftUI application
       ↓
Basic Mochi interface
       ↓
Interactive state
```

The first implementation should be small, real, and retained as the foundation for subsequent phases.

## 18. Definition of Success

Success is not:

> Mochi works because an assistant generated it.

Success is:

> Mochi works; the developer built and understands its important components, can debug and extend it independently, and can defend its technical decisions in a software engineering interview.

## 19. Source-of-Truth Policy

This specification represents the project's current intended product, architecture, sequencing, and learning philosophy. It is a living document, not an immutable contract.

If implementation reveals that a decision is poor:

1. Identify the evidence.
2. Explain the tradeoff.
3. Propose the change.
4. Update this specification if the change is accepted.

Do not preserve bad design merely because it appears here, and do not casually replace major decisions without explaining why.
