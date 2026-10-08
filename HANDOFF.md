# Handoff: URL Shortener — from system design to implementation

The user (a developer preparing for international/remote jobs) designed a URL shortener as a system-design exercise and now wants to **build it as a real project in this directory**. Nothing has been built yet; this directory was empty when this note was written and is not a git repository yet.

## Source of truth: the design diagram

`/home/smk/Documents/Trabalho na Gringa/system design/url-shortener.excalidraw.md` (Obsidian Excalidraw plugin file, in a git-tracked notes vault).

- **Readable part:** the `## Text Elements` section near the top contains every label, plus these panels — read them there, they are not repeated here:
  - Functional / Non-functional requirements
  - Capacity estimates (≈1.2k writes/s, ≈11.6k reads/s, 365B records, ≈36.5 TB, 7-char base62 keys, ≈20 GB cache)
  - Design decisions (10 numbered items: 302 redirects, cache-aside, QUORUM, TTL expiry, KGS batching, HA, rate limiting, no dedup, custom aliases via LWT, URL safety check)
  - Data model (Cassandra `urls` table)
- **Compressed part:** the `## Drawing` block is LZString `compressToBase64` JSON, split into 256-char lines with blank lines between. Decode it only if you need positions or connections. If you edit the drawing, re-compress it in the same format **and** keep the `Text Elements` section in sync, because the plugin reads text from there. Don't make backup copies; the vault is git-tracked.

## Architecture (the arrows exist only in the compressed JSON, so they are listed here)

```
Web Client ─HTTPS─┐
                  ├─> Load Balancer (x2) + Rate Limiter ──check quota──> Redis (rate-limit counters, token bucket)
Dashboard ─HTTPS──┘        │
                           ├─ GET /stats/{code} ─> Analytics API ──query──> Analytics DB (ClickHouse)
                           ├─ GET /{code} -> 302 ─> Redirect API (read-only)
                           │                          ├─ 1. get code ─────────> Redis Cache (LRU)
                           │                          ├─ 2. on miss: read (QUORUM) + fill cache ─> Cassandra
                           │                          └─ click event (async) ─> Kafka ─> Click Consumer ─aggregate─> ClickHouse
                           └─ POST /urls ────────> Write API
                                                      ├─ INSERT ... USING TTL (QUORUM) ─> Cassandra (RF=3, TTL 10y)
                                                      └─ take key batch ─> KGS (active + standby) ─mark batch used─> Key DB
```

## How the design was reviewed and changed (context, already applied to the diagram)

The original sketch had: client, dashboard, LB, redirect API, write API, KGS, Redis, Cassandra, Kafka, and a Cleanup service. The review found:
- Kafka had no consumer and the Dashboard had no data source → added the analytics pipeline.
- KGS was a single point of failure and had no storage → added a standby and a Key DB.
- Cleanup was redundant → replaced by a Cassandra TTL.
- A 301 redirect would break analytics → the redirect returns 302.
- The rate limiter needed shared state → added Redis counters.

Alternative mentioned but **not chosen**: generating keys from a counter with ID ranges (ZooKeeper/etcd) plus base62 encoding, instead of KGS. It's simpler, but the codes are sequential and guessable. Worth revisiting for a first version of the build.

## Open questions for the next session (ask the user — none were decided)

1. **Stack:** language/framework is undecided. The user's skills include Elixir/Phoenix, TypeScript, React/Vue.
2. **Scope of v1:** how much of the full design to build. The full design targets 100M URLs/day. A sensible v1 might be: Write API + Redirect API + one database + Redis cache + a key generator. Kafka/ClickHouse analytics and multi-node Cassandra would come later.
3. **Local infrastructure:** Docker Compose for Cassandra (or ScyllaDB), Redis, Kafka (or Redpanda), ClickHouse? Or start with Postgres to keep it simple?
4. **Goal:** portfolio piece, interview prep, or a production service? This affects tests, observability, deployment and README depth.

## Suggested skills for the next agent

- `superpowers:brainstorming`: run first to settle the open questions (stack, v1 scope, infrastructure) before any code.
- `adr-skill`: record the key decisions (KGS vs counter ranges, Cassandra vs Postgres for v1, 302 vs 301) as ADRs in this repo.
- `superpowers:writing-plans`: turn the agreed v1 scope into an implementation plan.
- `mattpocock-skills:tdd` or `superpowers:test-driven-development`: base62 encoding, key allocation and redirect logic are well suited to test-first development.
- `mattpocock-skills:domain-modeling`: if the user wants a `CONTEXT.md` glossary (short code, alias, key batch, click event).
- `superpowers:verification-before-completion`: before claiming anything works.

## User preferences learned

- Don't create backup copies before editing files; the user relies on git. Run `git init` here early and suggest committing as you go.
- The user writes in English but isn't a native speaker. Small grammar fixes in their notes were welcome.
