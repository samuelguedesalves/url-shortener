---
status: accepted
date: 2026-10-08
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Use Cassandra (separate keyspace) as the Key DB for the key generation service

## Context and Problem Statement

[ADR 0001](0001-use-a-key-generation-service-for-short-codes.md) chose a key generation service (KGS) that hands out batches of about 1,000 keys. It needs a Key DB that records each batch (`batch_id`, key set or range, `status`, `owner`) and stores the lease that decides which of the two KGS nodes is active. ADR 0001 leaves the technology open, and milestone 2 can't start without it.

The Key DB has three jobs that must not fail silently:

1. **Mark a batch used before handing it out**, atomically, so two callers never get the same batch.
2. **Keep that mark durable.** A lost "used" mark would let the same keys be handed out again, which is the one thing KGS must never do.
3. **Hold the leader lease** with compare-and-set, so only one node is active at a time.

Load is tiny: about 1.2 batch requests/s at the target of 1.2k writes/s with 1,000 keys per batch. Which datastore should back the Key DB?

## Decision Drivers

* **Atomic claim and compare-and-set lease**, without distributed locking code in the application.
* **Durability of the "used" mark** across a node loss.
* **No new datastore in Compose.** The stack is Cassandra, Kafka, Redis and ClickHouse (spec §1). Each extra datastore adds local-run weight, which the spec already flags as a risk.
* **Ownership.** The `kgs` app owns the Key DB. No other service reads or writes it (spec §2).
* **Operational honesty for a portfolio piece.** The ADR should state the costs of the choice, not only the benefits.

## Considered Options

* **Cassandra, separate keyspace (chosen).** Lightweight transactions (LWT) for the claim and the lease.
* **PostgreSQL.** Row locks and `SELECT ... FOR UPDATE SKIP LOCKED`.
* **Redis.** Lua scripts for atomicity.

## Decision Outcome

Chosen option: "**Cassandra, separate keyspace**", because it meets the atomicity and durability needs with LWT at QUORUM and adds no datastore to the stack. At about 1.2 requests/s, LWT's higher latency doesn't matter.

Design:

* A dedicated keyspace `kgs` with four tables, owned by the `kgs` app and created by an init script on `docker compose up`:
  * `batches` (`batch_id` partition key, `keys set<text>`, `status`, `owner`, `claimed_at`). The authoritative record of each batch.
  * `free_batches` (`pool` partition key, `batch_id` clustering key). A hint index of batches that were free when written. Stale entries are harmless, because the claim below is what decides.
  * `issued_keys` (`code` partition key). One row per key ever put into a batch, used to keep keys unique across batches.
  * `lease` (single row, `name` partition key, `owner`), written with `USING TTL`.
* **Creating batches (replenisher):** the active node keeps the pool of free batches above a low-water mark (config). For each batch it generates 1,000 random 7-char base62 keys and writes each with `INSERT INTO issued_keys (code) VALUES (?) IF NOT EXISTS`. Keys that were not applied (already issued) are replaced with new random ones. It then inserts the `batches` row with status `free` (`IF NOT EXISTS`, `batch_id` from a counter row advanced with an LWT) and the `free_batches` entry. Keys are random, not derived from a counter, as ADR 0001 requires, and `issued_keys` is what makes them unique across batches.
* **Claiming a batch:** `UPDATE batches SET status = 'used', owner = ?, claimed_at = ? WHERE batch_id = ? IF status = 'free'`. Only one caller sees `[applied] = true`, and a claim on a row that does not exist returns `[applied] = false`. The candidate `batch_id` comes from `free_batches`; if the claim is not applied, KGS tries the next candidate. After a successful claim, KGS deletes the `free_batches` entry and hands the batch out. The mark is written first, as ADR 0001 requires.
* **Taking the lease:** `INSERT INTO lease (name, owner) VALUES ('kgs', ?) IF NOT EXISTS USING TTL 10`.
* **Renewing the lease:** `UPDATE lease USING TTL 10 SET owner = ? WHERE name = 'kgs' IF owner = ?`. A deposed node's renewal fails because the owner no longer matches.
* **Consistency:** QUORUM for reads and writes, SERIAL for the LWT condition. RF=3 in production, RF=1 locally (config, as in the spec).
* **Client:** Xandra, over the CQL native protocol, which supports LWT results (`[applied]`).
* **Unknown outcome:** an LWT that times out may or may not have applied. KGS treats a timed-out claim as used and discards the batch. This wastes a batch and never reissues one.

### Consequences

* Good, because the stack stays at four datastores, so `docker compose up` doesn't gain a fifth.
* Good, because the claim and the lease are single conditional statements, so there is no application-level locking.
* Good, because `USING TTL` on the lease row expires a dead node's lease automatically, with no cleanup job.
* Bad, because LWT (Paxos) is slower and heavier than a plain write. This is accepted at about 1.2 requests/s, and it would matter at far higher batch rates.
* Bad, because the Key DB shares the cluster's failure domain with `urls`. If Cassandra is down, writes already fail with 503 (spec §10), and KGS can't hand out new batches either. This adds no new failure mode for the write path, but it removes the isolation a separate store would give.
* Bad, because `issued_keys` holds one row per key ever generated, so it grows about as fast as `urls` (the spec's capacity estimate is 365B records). Random 7-char keys collide often at that scale (roughly 10% per new key at 365B of 3.5T), so the guard is required, not optional. Its cost is one LWT per key, paid in the background by the replenisher, not on the request path. Rows should be written `USING TTL` matching the URL TTL so the table can shrink.
* Bad, because an LWT timeout has an unknown outcome, so some batches are wasted. The same negligible-waste argument as in ADR 0001 applies.
* Neutral, because the keyspace can move to its own cluster later by changing the contact points in config, since only `kgs` uses it.

## Implementation Plan

* **Affected paths**:
  * `apps/kgs/`: keyspace and table schema, claim and lease queries, Xandra connection.
  * `docker-compose.yml` and an init script (for example `docker/cassandra/init-kgs.cql`): create the `kgs` keyspace and tables on startup.
  * `README.md`: the KGS section links to this ADR.
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §6: name Cassandra as the Key DB.
* **Dependencies**: add `xandra` to `apps/kgs` only. Pin the version when the app is scaffolded.
* **Patterns to follow**:
  * Every claim and lease write is a conditional statement, and the code checks `[applied]` on the result.
  * Treat a timeout on an LWT as "applied", so the batch is discarded.
  * `kgs` is the only app with the `kgs` keyspace in its config.
* **Patterns to avoid**:
  * No read-then-write for claiming or leasing, because that is a race.
  * No `UPDATE` without an `IF` condition on `batches.status` or `lease.owner`.
  * No access to the `kgs` keyspace from `write_api`, `redirect_api` or any other app. They go through the KGS HTTP API.
* **Configuration**: `KGS_CASSANDRA_NODES`, `KGS_KEYSPACE` (default `kgs`), `KGS_REPLICATION_FACTOR` (3 in production, 1 locally), `KGS_LEASE_TTL` (default 10 s, from ADR 0001), `KGS_LOW_WATER_BATCHES` (default 20 free batches).
* **Migration steps**: not applicable, since nothing exists yet.

### Verification

- [ ] A concurrency test that claims the same batch from many processes yields exactly one `[applied] = true`.
- [ ] A claim on a `batch_id` that has no row returns `[applied] = false` and does not create one.
- [ ] Two batches created concurrently never contain the same key (checked against `issued_keys`).
- [ ] The replenisher keeps the number of free batches at or above the low-water mark while keys are being claimed.
- [ ] A stale `free_batches` entry (batch already claimed) is skipped without handing out a batch twice.
- [ ] A claim whose LWT times out is never handed out again (tested with an injected timeout).
- [ ] Only one node holds the lease at a time, and a stale holder's renewal returns `[applied] = false`.
- [ ] After the lease row's TTL passes without renewal, the standby acquires the lease.
- [ ] `docker compose up` creates the `kgs` keyspace and tables with no manual step.
- [ ] No app other than `kgs` has the `kgs` keyspace in its config (a repo grep in CI, or a test).
- [ ] No unconditional `UPDATE` on `batches` or `lease` exists in `apps/kgs` (a grep in CI, or code review).

## Pros and Cons of the Options

### Cassandra, separate keyspace

* Good, because there is no new datastore.
* Good, because LWT gives atomic claim and compare-and-set lease, and TTL gives lease expiry.
* Good, because QUORUM writes are durable across a node loss.
* Bad, because LWT is slow and can time out with an unknown result.
* Bad, because it shares the cluster's failure domain with `urls`.

### PostgreSQL

* Good, because transactions, row locks and `SKIP LOCKED` make the claim and lease simple and well understood.
* Good, because it isolates the Key DB's failures from `urls`.
* Bad, because it adds a fifth datastore to Compose, which the spec already flags as a weight risk.
* Bad, because production HA means running replication for a store that holds only a small table.

### Redis

* Good, because it is already in the stack, and Lua gives atomic claim and lease.
* Bad, because a restart or failover can lose the "used" marks, depending on persistence settings, which breaks the never-reuse guarantee.
* Bad, because tuning Redis for durability works against why it is used elsewhere in this system (cache and rate limiter).

## More Information

* Depends on [ADR 0001](0001-use-a-key-generation-service-for-short-codes.md). Related ADR planned: QUORUM consistency.
* Decision recorded without your input: how batches are populated (random keys plus `issued_keys`) was chosen by the drafting agent because ADR 0001 forbids counter-derived codes. If you prefer another scheme, such as a keyed permutation of a counter, that requires amending ADR 0001 first.
* Revisit if: `issued_keys` growth or its background LWT cost becomes a problem, if LWT latency or timeouts show up in KGS metrics, if batch request rates grow by orders of magnitude, or if the shared failure domain with `urls` becomes a problem. Moving the keyspace to its own cluster is the first step.
* Open question: whether Xandra is the right client. It is chosen here as the common Elixir CQL driver, and it is worth checking against the real LWT behaviour when milestone 2 starts.

* 2026-10-09: amended by [ADR 0004](0004-expire-links-with-a-ttl-on-the-destination-and-never-reuse-codes.md). `issued_keys` rows are written **without** a TTL, so generated keys are never reissued. This replaces the earlier suggestion to write them `USING TTL`, which is why the growth of `issued_keys` is now unbounded.
