"""Bounded response cache and a separate local, first-party feedback store."""

import json
import sqlite3
import threading
import time
from pathlib import Path


class ProviderCache:
    # Conservatively below Last.fm's 100 MB allowance. No embeddings are persisted.
    def __init__(self, path: Path, *, max_bytes=40_000_000, clock=time.time):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.execute("PRAGMA journal_mode=DELETE")
        self.connection.execute("PRAGMA auto_vacuum=FULL")
        self.connection.execute("CREATE TABLE IF NOT EXISTS responses (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires REAL NOT NULL, accessed REAL NOT NULL)")
        self.connection.commit()
        self.max_bytes, self.clock = max_bytes, clock
        self.lock = threading.RLock()

    def get(self, key):
        with self.lock, self.connection:
            now = self.clock()
            self.connection.execute("DELETE FROM responses WHERE expires <= ?", (now,))
            row = self.connection.execute("SELECT value FROM responses WHERE key=?", (key,)).fetchone()
            if row:
                self.connection.execute("UPDATE responses SET accessed=? WHERE key=?", (now, key))
                return json.loads(row[0])
        return None

    def put(self, key, value, ttl):
        if ttl <= 0:
            return
        encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode()) + len(key.encode()) > self.max_bytes // 2:
            return
        with self.lock, self.connection:
            now = self.clock()
            self.connection.execute("DELETE FROM responses WHERE expires <= ?", (now,))
            self.connection.execute("INSERT OR REPLACE INTO responses VALUES (?,?,?,?)", (key, encoded, now + ttl, now))
            # Count real SQLite pages, not just payloads. FULL auto-vacuum reclaims
            # deleted pages at commit, keeping the on-disk file bounded too.
            self.connection.commit()
            while self.size_bytes() > self.max_bytes:
                oldest = self.connection.execute("SELECT key FROM responses ORDER BY accessed, rowid LIMIT 1").fetchone()
                if not oldest:
                    break
                self.connection.execute("DELETE FROM responses WHERE key=?", oldest)
                self.connection.commit()

    def remaining(self, key):
        with self.lock:
            row = self.connection.execute("SELECT expires FROM responses WHERE key=?", (key,)).fetchone()
            return max(0, row[0] - self.clock()) if row else 0

    def size_bytes(self):
        with self.lock:
            pages = self.connection.execute("PRAGMA page_count").fetchone()[0]
            size = self.connection.execute("PRAGMA page_size").fetchone()[0]
            return pages * size

    def close(self):
        self.connection.close()


class TasteStore:
    """Store our prompts, opaque recording/artist keys, and explicit actions.

    No Spotify history, provider descriptions, or embeddings are persisted here.
    Requests expire after 30 days; feedback keeps the latest 10,000 events.
    """
    def __init__(self, path: Path, *, clock=time.time):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.lock, self.clock = threading.RLock(), clock
        self.connection.executescript("""
            PRAGMA auto_vacuum=FULL;
            CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, prompt TEXT NOT NULL, tracks TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS feedback (event_id TEXT PRIMARY KEY, request_id TEXT NOT NULL, track_id TEXT NOT NULL, artist_key TEXT NOT NULL, event TEXT NOT NULL, created REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS feedback_track ON feedback(track_id, created);
        """)

    def save_request(self, request_id, prompt, tracks):
        from music import artist_key
        # Metadata names stay in the disposable provider cache. These keys are
        # sufficient for feedback and artist affinity when new candidates arrive.
        entries = {track.id: artist_key(track.artist) for track in tracks}
        with self.lock, self.connection:
            self.connection.execute("DELETE FROM requests WHERE created < ?", (self.clock() - 30 * 86400,))
            self.connection.execute("INSERT INTO requests VALUES (?,?,?,?)", (request_id, prompt, json.dumps(entries), self.clock()))

    def feedback(self, event_id, request_id, track_id, event):
        with self.lock, self.connection:
            existing = self.connection.execute("SELECT request_id, track_id, event FROM feedback WHERE event_id=?", (event_id,)).fetchone()
            if existing:
                if existing != (request_id, track_id, event):
                    raise ValueError("Feedback event ID was already used")
                return
            row = self.connection.execute("SELECT tracks FROM requests WHERE id=? AND created>=?", (request_id, self.clock() - 30 * 86400)).fetchone()
            tracks = json.loads(row[0]) if row else {}
            if track_id not in tracks:
                raise ValueError("Choose a track from a recent recommendation")
            self.connection.execute("INSERT INTO feedback VALUES (?,?,?,?,?,?)", (event_id, request_id, track_id, tracks[track_id], event, self.clock()))
            self.connection.execute("DELETE FROM feedback WHERE event_id IN (SELECT event_id FROM feedback ORDER BY created DESC, rowid DESC LIMIT -1 OFFSET 10000)")

    def snapshot(self):
        with self.lock:
            rows = self.connection.execute("SELECT track_id, artist_key, event, created FROM feedback ORDER BY created, rowid").fetchall()
        preferences, artists, recent, favorites = {}, {}, [], []
        for track, artist, event, created in rows:
            if event in {"like", "dislike"}:
                preferences[track] = (artist, 1 if event == "like" else -1)
            elif event in {"select", "replay"} and created >= self.clock() - 86400:
                recent.append(track)
        for track, (artist, value) in preferences.items():
            artists[artist] = artists.get(artist, 0) + value
            if value > 0:
                favorites.append(track)
        return {"tracks": {key: value[1] for key, value in preferences.items()},
                "artists": artists, "recent": recent[-20:], "favorites": favorites[-3:]}

    def clear(self):
        with self.lock, self.connection:
            self.connection.execute("DELETE FROM feedback")
            self.connection.execute("DELETE FROM requests")

    def close(self):
        self.connection.close()
