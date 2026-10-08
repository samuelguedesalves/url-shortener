# URL Shortener: Design Spec

Date: 2026-10-07
Source diagram: `/home/smk/Documents/Trabalho na Gringa/system design/url-shortener.excalidraw.md` (requirements, capacity estimates and the 10 design decisions live there; they are not repeated here).

## 1. Intent

**Outcome:** a portfolio-grade URL shortener in Elixir/Phoenix that implements the full system-design diagram: Write and Redirect APIs, Redis cache-aside, Cassandra storage, a key generation service (KGS) with standby and Key DB, Redis rate limiting, a Kafka to ClickHouse analytics pipeline, a stats API, a dashboard, and a URL safety check.

**Success criteria:**
- `docker compose up` starts the whole system locally on real Apache Cassandra and Apache Kafka.
- The README explains the architecture clearly. ADRs record the key decisions (302 vs 301, KGS vs counter ranges, QUORUM, TTL expiry, at-least-once analytics).
- Solid automated tests, including integration tests against the real datastores, and a recorded load-test result for the redirect path.

**Decisions made with the user:**
- Purpose: portfolio piece (tests, docs and architecture story outweigh deployment concerns).
- Stack: Elixir/Phoenix.
- Scope: the full design in one spec, organised into ordered milestones.
- Infrastructure: exact diagram stack (Cassandra, Apache Kafka, Redis, ClickHouse).
- Structure: Elixir umbrella, one OTP app per service.

**Assumptions (not stated by the user):** services stay logically separate; git is initialised early and work is committed as it goes.

**Known risk:** a real Cassandra plus Kafka stack is heavy locally. Compose runs a single node of each. RF=3 and QUORUM are configuration; local runs use RF=1 and the ADR documents the production setting.

## 2. Layout and boundaries

```
url_shortener/            (umbrella)
├── apps/
│   ├── shortener_core    shared: base62, Url schema, Cassandra/Redis clients, KeySource behaviour
│   ├── edge              LB-facing: rate limiter plug (Redis token bucket) + routing
│   ├── write_api         POST /urls
│   ├── redirect_api      GET /{code}
│   ├── kgs               key batch service: Key DB, batch hand-out, active/standby
│   ├── click_consumer    Kafka -> aggregate -> ClickHouse
│   └── analytics_api     GET /stats/{code}
├── dashboard/            React or Vue SPA (not an Elixir app)
├── docker-compose.yml    2 nginx LBs, Redis, Cassandra, Kafka, ClickHouse, Key DB, services
└── docs/adr/             one decision per file
```

- Services communicate only over HTTP, Kafka, or their own datastore. They never call another service's modules.
- `shortener_core` is the only shared app and holds no service logic.
- `shortener_core` defines a `KeySource` behaviour. `kgs` is the real implementation. A simple in-process generator implements the same behaviour for early milestones and tests.

## 3. Data model

Cassandra `urls` table:
- Partition key `code` (7-char base62). Columns: `long_url`, `created_at`, `owner_id`, `is_custom_alias`.
- Rows are written `USING TTL` (default 10 years, or the user's expiry).
- Keyspace replication factor comes from config (RF=3 in production, RF=1 locally).

## 4. Write path (`POST /urls`)

1. Edge rate limiter checks the Redis token bucket; 429 when the quota is spent.
2. `write_api` validates the URL and runs the safety check.
3. Generated code: take a key from the local batch; when exhausted, request a new batch from KGS. Then `INSERT ... IF NOT EXISTS` at QUORUM.
4. Custom alias: skip KGS, use `INSERT ... IF NOT EXISTS` (LWT); a clash returns 409.
5. Respond 201 with the short URL. No deduplication: the same long URL gets a new code each time.

## 5. Read path (`GET /{code}`)

1. Redis lookup (LRU, cache-aside). A hit returns 302.
2. A miss reads Cassandra at QUORUM and fills the cache; cache TTL is capped by the row's remaining TTL. Unknown codes return 404 and get a short negative-cache entry.
3. Fire-and-forget click event to Kafka, off the request's critical path. If Kafka is down, the redirect still succeeds; the dropped event is counted in a metric.

## 6. KGS

- The Key DB records batches (`batch_id`, key set or range, status, owner).
- `write_api` takes batches of about 1,000 keys. KGS marks a batch used before handing it out, so a crash wastes keys but never reuses them.
- Active and standby nodes; the standby takes over through a lease stored in the Key DB.

## 7. Analytics pipeline

- Redirect API publishes `{code, ts, referrer, country, user_agent_class}` to a Kafka topic partitioned by `code`.
- `click_consumer` is a Broadway pipeline. It batches events and writes aggregates to ClickHouse (a `SummingMergeTree` table of clicks per code per hour). Offsets are committed only after a successful insert (at-least-once).
- `analytics_api` serves `GET /stats/{code}` with totals and a time series. Counts are documented as approximate because delivery can duplicate events (ADR).

## 8. Rate limiting

`edge` Plug with a token bucket in Redis. A Lua script makes check-and-decrement atomic. Keyed by client IP or API key; sends `Retry-After` on 429. If Redis is unreachable it fails open and records a metric.

## 9. URL safety check

A `SafetyChecker` behaviour called by `write_api`. Local rule-based implementation (scheme allowlist, blocked-host list, no private IPs) plus a pluggable adapter for an external API such as Google Safe Browsing. The local checker ships first; the external adapter is only the interface.

## 10. Failure behaviour

| Failure | Behaviour |
|---|---|
| Cassandra down | Writes return 503; reads still served from cache |
| Redis down | Reads go straight to Cassandra; rate limiter fails open; metrics record both |
| Kafka down | Redirects unaffected; dropped events counted |
| KGS down | `write_api` serves from its remaining batch, then 503 for generated codes; custom aliases still work |

## 11. Observability

Telemetry and Prometheus metrics: cache hit ratio, redirect latency, KGS batch usage. Structured logs with a request ID on every request. `/health` on every service.

## 12. Testing

- Unit tests (test-first): base62, token bucket logic, URL validation.
- Integration tests against real Cassandra, Redis, Kafka and ClickHouse via Docker Compose, tagged so they can be excluded.
- Contract tests for the `KeySource` and `SafetyChecker` behaviours.
- End-to-end smoke script: create a URL, redirect, produce a click, read the stats.
- k6 load test on the redirect path; results recorded in the README.

## 13. Milestones (build order)

1. Core path: write, redirect, cache, Cassandra, Compose, test scaffolding, `KeySource` with the in-process generator.
2. KGS and Key DB, including standby.
3. Rate limiting.
4. Analytics pipeline and stats API.
5. Dashboard and URL safety check.
6. HA (two load balancers), load test, README polish, ADRs finalised.

Each milestone is built and verified on its own before the next starts.

## 14. Out of scope

Authentication and user accounts beyond an `owner_id`/API key, multi-region deployment, a real three-node Cassandra cluster, and Kubernetes deployment.
