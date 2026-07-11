import Foundation

/// Forward-only schema migrations, keyed to `PRAGMA user_version`. A migration is
/// applied iff its `version` exceeds the DB's current `user_version`; the runner
/// applies the gap in one transaction and bumps the version. Never edit a shipped
/// migration — add a new one.
///
/// Schema mirrors tech-spec §2. Timestamps are REAL unix-epoch seconds; ids are TEXT
/// UUIDs; `text_hash` is stored as hex TEXT (our SHA-256 hex) rather than BLOB.
///
/// Migration 2 adds `chunk_vectors` as a PLAIN int8 table (embedding + per-vector
/// scale), read by the brute-force `VectorIndex`. The sqlite-vec `vec0` virtual table
/// is a LATER migration once the extension is linked — it becomes an in-DB ANN index
/// built from these durable int8 rows; `chunk_vectors` stays the source of truth (the
/// `RetrievalStore`/`VectorIndex` hedge means feature code never depends on which).
public enum CatalogSchema {

    public struct Migration: Sendable {
        public let version: Int
        public let sql: String
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, sql: v1),
        Migration(version: 2, sql: v2),
    ]

    /// Highest known schema version (the target after a full migrate).
    public static var currentVersion: Int { migrations.map(\.version).max() ?? 0 }

    private static let v1 = """
    CREATE TABLE schema_meta (
        key   TEXT PRIMARY KEY,
        value TEXT
    );

    CREATE TABLE episodes (
        id           TEXT PRIMARY KEY,
        ts_start     REAL NOT NULL,
        ts_end       REAL NOT NULL,
        bundle_id    TEXT NOT NULL,
        app_name     TEXT NOT NULL,
        window_title TEXT,
        url          TEXT,
        summary      TEXT,
        entity_keys  TEXT               -- json array
    );
    CREATE INDEX idx_episodes_ts_start ON episodes(ts_start);
    CREATE INDEX idx_episodes_bundle_ts ON episodes(bundle_id, ts_start);

    CREATE TABLE events (
        id              TEXT PRIMARY KEY,
        episode_id      TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        ts              REAL NOT NULL,
        event_type      TEXT NOT NULL CHECK(event_type IN ('screen_text','audio','clipboard')),
        source          TEXT NOT NULL CHECK(source IN ('ax','ocr','asr')),
        confidence      REAL NOT NULL DEFAULT 1.0,
        raw_text        TEXT NOT NULL,
        text_hash       TEXT,
        redaction_flags INTEGER NOT NULL DEFAULT 0,
        provenance      TEXT NOT NULL DEFAULT 'untrusted_ambient'
    );
    CREATE INDEX idx_events_episode ON events(episode_id);
    CREATE INDEX idx_events_text_hash ON events(text_hash);

    CREATE TABLE chunks (
        id          TEXT PRIMARY KEY,
        episode_id  TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
        event_id    TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        text        TEXT NOT NULL,
        token_count INTEGER NOT NULL,
        ts_capture  REAL NOT NULL,
        ts_event    REAL,
        source      TEXT NOT NULL CHECK(source IN ('ax','ocr','asr')),
        model_id    TEXT,
        dim         INTEGER,
        minhash     BLOB
    );
    CREATE INDEX idx_chunks_ts_capture ON chunks(ts_capture);
    CREATE INDEX idx_chunks_ts_event ON chunks(ts_event);
    CREATE INDEX idx_chunks_episode ON chunks(episode_id);

    -- Full-text search over chunk text (external-content, synced by triggers).
    CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='rowid');
    CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER chunks_au AFTER UPDATE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    -- Audio lane (populated at M1.5). speaker_label is a per-meeting label only.
    CREATE TABLE meetings (
        id             TEXT PRIMARY KEY,
        ts_start       REAL NOT NULL,
        ts_end         REAL,
        app            TEXT,
        title          TEXT,
        consent_status TEXT NOT NULL DEFAULT 'pending'
                       CHECK(consent_status IN ('pending','granted','declined'))
    );
    CREATE TABLE audio_segments (
        id            TEXT PRIMARY KEY,
        meeting_id    TEXT REFERENCES meetings(id) ON DELETE SET NULL,
        ts            REAL NOT NULL,
        transcript    TEXT NOT NULL,
        speaker_label TEXT
    );
    CREATE TABLE consent_log (   -- append-only (enforced by DAO + review)
        id         TEXT PRIMARY KEY,
        meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
        ts         REAL NOT NULL,
        method     TEXT NOT NULL,
        note       TEXT
    );

    -- Capture exclusion rules (mirrors ExclusionSet; UI-managed later).
    CREATE TABLE exclusions (
        id         TEXT PRIMARY KEY,
        rule_type  TEXT NOT NULL CHECK(rule_type IN ('app','url','window','regex','schedule')),
        pattern    TEXT NOT NULL,
        mode       TEXT NOT NULL CHECK(mode IN ('never_capture','redact')),
        created_at REAL NOT NULL
    );

    -- Filing pipeline (M3). Present now so migrations stay forward-only.
    CREATE TABLE filing_drafts (
        id               TEXT PRIMARY KEY,
        recipe           TEXT NOT NULL,
        created_at       REAL NOT NULL,
        payload          TEXT NOT NULL,          -- schema-validated json
        source_event_ids TEXT,                   -- json array
        content_hash     TEXT,
        external_key     TEXT UNIQUE,            -- client-side idempotency
        status           TEXT NOT NULL DEFAULT 'draft'
                         CHECK(status IN ('draft','approved','committed','dismissed','undone')),
        committed_at     REAL,
        external_system  TEXT,
        external_id      TEXT
    );
    CREATE INDEX idx_drafts_status_created ON filing_drafts(status, created_at);

    CREATE TABLE write_ledger (   -- append-only, drives undo
        id          TEXT PRIMARY KEY,
        draft_id    TEXT REFERENCES filing_drafts(id) ON DELETE SET NULL,
        ts          REAL NOT NULL,
        action      TEXT NOT NULL CHECK(action IN ('create','append','archive')),
        target_id   TEXT,
        payload_sha TEXT,
        diff        TEXT
    );

    CREATE TABLE egress_ledger (  -- append-only, user-visible
        id               TEXT PRIMARY KEY,
        ts               REAL NOT NULL,
        process          TEXT NOT NULL,
        destination_host TEXT NOT NULL,
        purpose          TEXT NOT NULL,
        byte_count       INTEGER,
        payload_sha      TEXT,
        trigger          TEXT
    );
    CREATE INDEX idx_egress_ts ON egress_ledger(ts);

    CREATE TABLE agent_runs (
        id           TEXT PRIMARY KEY,
        recipe       TEXT NOT NULL,
        ts           REAL NOT NULL,
        runner       TEXT NOT NULL CHECK(runner IN ('api','subscription','local')),
        model        TEXT,
        tokens_in    INTEGER,
        tokens_out   INTEGER,
        est_cost_usd REAL,
        status       TEXT,
        error        TEXT
    );

    CREATE TABLE destinations (
        id              TEXT PRIMARY KEY,
        system          TEXT NOT NULL CHECK(system IN ('notion')),
        config          TEXT,
        autonomy        TEXT NOT NULL DEFAULT 'manual' CHECK(autonomy IN ('manual','earned_auto')),
        unedited_streak INTEGER NOT NULL DEFAULT 0
    );
    """

    /// Vector store: one int8 embedding per chunk, keyed for lazy per-model re-embed.
    /// `embedding` is `dim` signed bytes; `scale` dequantizes (`float ≈ int8 * scale`).
    /// CASCADE so a chunk's vector dies with it (and with a whole-shard purge).
    private static let v2 = """
    CREATE TABLE chunk_vectors (
        chunk_id  TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
        model_id  TEXT NOT NULL,
        dim       INTEGER NOT NULL,
        scale     REAL NOT NULL,
        embedding BLOB NOT NULL
    );
    CREATE INDEX idx_chunk_vectors_model ON chunk_vectors(model_id);
    """
}
