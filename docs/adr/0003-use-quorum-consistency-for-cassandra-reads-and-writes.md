---
status: accepted
date: 2026-10-09
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Use QUORUM consistency for Cassandra reads and writes

## Context and Problem Statement

Cassandra lets each statement choose a consistency level. The [design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) already assumes QUORUM on the write path (§4) and on the cache-miss read (§5), and [ADR 0001](0001-use-a-key-generation-service-for-short-codes.md) and [ADR 0002](0002-use-cassandra-as-the-key-db-for-the-key-generation-service.md) both rely on conditional statements (`IF NOT EXISTS`, `IF status = 'free'`, `IF owner = ?`) that depend on it. No ADR states the rule or its consequences. It has to be fixed before the shared Cassandra client in `shortener_core` is written, because every service will inherit its defaults.

The key requirement: **a link must resolve immediately after `POST /urls` returns 201**, from any replica. Which consistency levels should reads and writes use, and what should happen when that level can't be met?

## Decision Drivers

* **Read-your-writes on the redirect path.** A fresh link that 404s is the failure users notice, and a 404 can be cached (spec §5, negative-cache entry).
* **Conditional statements need a quorum.** `IF NOT EXISTS` and `IF` conditions use SERIAL for the condition and need the write to be durable on a majority.
* **Survive one replica down.** With RF=3, one node can fail without stopping reads or writes.
* **Single region.** Multi-region consistency is out of scope (spec §14), so QUORUM and LOCAL_QUORUM are equivalent.
* **Local runs use RF=1** (spec §1). At RF=1, QUORUM equals ONE, so the code path is the same and the guarantee is only tested at RF=3.

## Considered Options

* **QUORUM for reads and writes (chosen).**
* **Write QUORUM, read ONE / LOCAL_ONE.**
* **Write ALL, read ONE.**

## Decision Outcome

Chosen option: "**QUORUM for reads and writes**", because with RF=3 the read and write quorums overlap (2 + 2 > 3), so a QUORUM read always sees the latest acknowledged QUORUM write, from any replica. It also tolerates one replica down for both reads and writes.

Rules:

* **Plain reads and writes on `urls`:** QUORUM.
* **Conditional statements** (`INSERT ... IF NOT EXISTS`, `UPDATE ... IF ...`, including the Key DB statements in ADR 0002): serial consistency SERIAL for the condition and QUORUM for the commit.
* **RF** comes from config: 3 in production and 1 locally. Consistency levels are the same in both.
* **Quorum not available** (two of three replicas down):
  * Writes return 503.
  * Cache-miss reads return **503, not 404**, so a failure is never reported or cached as "not found".
  * Cache hits keep redirecting (spec §10).
* **Negative cache:** a 404 is cached only after a successful QUORUM read that found no row, with a short TTL. Creating a link (generated or custom alias) deletes any negative-cache entry for its code, so a custom alias is not hidden by an earlier miss.

### Consequences

* Good, because a link resolves right after the 201, from any replica, so there is no stale-read 404 to explain or cache.
* Good, because one replica can be down without any impact on reads or writes.
* Good, because the same consistency rule covers `urls` and the Key DB, so there is one thing to know.
* Bad, because cache-miss reads are slower than `ONE` reads and touch two replicas. The cache absorbs most reads (about 20 GB cache, spec §1), so this lands only on misses.
* Bad, because with two replicas down all misses and all writes return 503, where a read at `ONE` would still succeed. This is accepted: the spec's failure table (§10) already has writes return 503 when Cassandra is down.
* Bad, because the guarantee exists only at RF=3. Local runs at RF=1 cannot show a stale read, so the replica-spanning test needs a multi-node setup or is documented as unverified locally.
* Neutral, because the negative-cache delete on create adds one Redis call to the write path. If Redis is down, the call is skipped and the short negative TTL bounds the damage.

## Implementation Plan

* **Affected paths**:
  * `apps/shortener_core/`: the Cassandra client wrapper sets QUORUM (and SERIAL for conditionals) as the default, and exposes no per-call override.
  * `apps/write_api/`: the insert uses the shared client, and deletes the negative-cache entry after a successful insert.
  * `apps/redirect_api/`: the cache-miss read uses the shared client, maps "quorum unavailable" to 503, and writes the negative cache only after a successful empty read.
  * `apps/kgs/`: Key DB statements use the shared client's conditional-statement defaults (ADR 0002).
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §5 and §10: reference this ADR for the 503-not-404 rule.
  * `README.md`: a consistency section that links to this ADR.
* **Dependencies**: none new. The Cassandra driver is already decided in ADR 0002 (Xandra), and `shortener_core` wraps it.
* **Patterns to follow**: every `urls` and `kgs` statement goes through the `shortener_core` client wrapper, so the consistency level is set in one place.
* **Patterns to avoid**:
  * No per-statement consistency override at call sites.
  * No reading at `ONE` or `LOCAL_ONE` to "optimize" the redirect path.
  * No caching of a 404 after a failed or timed-out read.
* **Configuration**: `CASSANDRA_REPLICATION_FACTOR` (3 in production, 1 locally), `NEGATIVE_CACHE_TTL` (default 30 s).
* **Migration steps**: not applicable, since nothing exists yet.

### Verification

- [ ] The `shortener_core` client sets QUORUM on every `urls` statement and SERIAL on conditionals, and a grep or test shows no call site overrides it.
- [ ] On a 3-node cluster (or the closest available setup), a `POST /urls` that returns 201 is followed by a successful redirect through a different replica. If only RF=1 is available locally, this item is marked unverified in the README.
- [ ] With replicas down below quorum, a cache miss returns 503 and nothing is added to the negative cache.
- [ ] A successful empty QUORUM read caches a 404 with `NEGATIVE_CACHE_TTL`, and creating a link with that code (including a custom alias) deletes the entry and the next redirect succeeds.
- [ ] With Cassandra down, a cache hit still redirects.
- [ ] With Cassandra down, `POST /urls` returns 503.

## Pros and Cons of the Options

### QUORUM for reads and writes

* Good, because read-your-writes holds from any replica.
* Good, because it tolerates one replica down for reads and writes.
* Bad, because misses are slower and need two replicas.
* Bad, because two replicas down stops all misses and writes.

### Write QUORUM, read ONE / LOCAL_ONE

* Good, because misses are faster and cheaper, and reads survive two replicas down.
* Bad, because a fresh link can 404 on a lagging replica, and that 404 can be negative-cached.
* Bad, because conditional statements and their reads would need a different rule, which makes the client harder to reason about.

### Write ALL, read ONE

* Good, because read-your-writes holds and reads are cheap.
* Bad, because one replica down blocks every write, which contradicts the goal of surviving a node loss.

## More Information

* Depends on [ADR 0001](0001-use-a-key-generation-service-for-short-codes.md) and [ADR 0002](0002-use-cassandra-as-the-key-db-for-the-key-generation-service.md). Related ADR planned: TTL expiry, which affects how long cached and negative-cached entries may live.
* Revisit if: cache-miss latency at QUORUM shows up in the redirect p99 under the k6 load test (spec §12), if a multi-region deployment is added (move to LOCAL_QUORUM with a cross-region policy), or if misses returning 503 during partial outages proves worse in practice than serving a stale read.

* 2026-10-09: amended by [ADR 0004](0004-expire-links-with-a-ttl-on-the-destination-and-never-reuse-codes.md). The write to `urls` is now two statements (a claim `INSERT ... IF NOT EXISTS` with no TTL, then an `UPDATE ... USING TTL` for the destination), both under the consistency rules here. A row with no `long_url` returns 410, which is not a "not found" and is never cached as a plain 404.
