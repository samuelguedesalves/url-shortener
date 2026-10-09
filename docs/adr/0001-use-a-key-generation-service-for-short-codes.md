---
status: accepted
date: 2026-10-08
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Use a key generation service (KGS) with batched keys for short codes

## Context and Problem Statement

Every short URL needs a unique 7-character base62 code (62^7 ≈ 3.5 trillion codes). The system targets about 1.2k writes/s ([design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §1, §4). `shortener_core` defines a `KeySource` behaviour; milestone 1 ships an in-process generator behind it, and milestone 2 builds the real implementation. The choice has to be fixed before the `kgs` app, its Key DB, and the `write_api` batch client exist, because changing it later means rewriting the Key DB schema, the lease logic, and the write path.

How should `write_api` obtain a unique code for each new short URL without collisions on the hot path?

## Decision Drivers

* **Collision-free by construction.** The write path should not need a retry loop to find an unused code.
* **No coordination service.** No ZooKeeper or etcd to run, because the stack is already Cassandra, Kafka, Redis, ClickHouse, and nginx.
* **Services stay independent.** Services talk only over HTTP, Kafka, or their own datastore ([spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §2). `kgs` must be reachable over HTTP and own its data.
* **Survives a node loss.** KGS needs an active/standby pair with its state in a Key DB, so one node is not a single point of failure.
* **Portfolio value.** The system-design diagram includes KGS, and building it is part of the goal.

## Considered Options

* **KGS with batches (chosen).** A Key DB records key batches. `write_api` requests about 1,000 keys at a time and serves codes from its local pool.
* **Counter ranges plus base62.** A coordinator hands out ID ranges. Each writer increments within its range and base62-encodes the number.
* **Random generation plus retry on collision.** `write_api` generates a random 7-char code and retries `INSERT ... IF NOT EXISTS` until it succeeds.

## Decision Outcome

Chosen option: "**KGS with batches**", because it is the only option that is collision-free by construction without a coordination service. Counter ranges need ZooKeeper or etcd. Random generation pays a retry on the write path that grows as the table fills.

How it works:

* The `kgs` app owns a Key DB with a `batches` record per batch (`batch_id`, key set or range, `status`, `owner`).
* `write_api` asks KGS for a batch of about 1,000 keys and serves generated codes from it. When the local batch runs out, it asks for another.
* KGS marks a batch as used **before** handing it out. A crash can waste the unused keys of a batch but can never hand the same key out twice.
* KGS runs as an active node and a standby. The standby takes over through a lease stored in the Key DB.

### Custom aliases and generated keys

KGS guarantees uniqueness only among generated keys. Custom aliases live in the same `code` partition key in Cassandra, so a user can claim an alias that KGS later hands out. This is accepted:

* `write_api` always writes with `INSERT ... IF NOT EXISTS` at QUORUM, for generated codes too.
* If a generated key clashes with an existing alias, `write_api` discards that key and takes the next one from the batch. Retries are capped at 3 per request. After that the request fails with 503.
* Custom aliases are not restricted in shape. Their clash with a user's alias is a 409, as the spec already says.

### Consequences

* Good, because the common path (take a key from the local batch, then insert) has no collision-retry loop. Clashes happen only against custom aliases, which is rare.
* Good, because codes are not derived from a counter, so they are not sequential or enumerable.
* Good, because `write_api` serves from its local batch while KGS is down, so a short KGS outage does not stop writes.
* Bad, because there is an extra service, a Key DB, and a leader lease to build, run, and test.
* Bad, because a crash wastes the unused keys of in-flight batches. With about 1,000 keys per batch out of 3.5 trillion, this is negligible and accepted.
* Bad, because KGS only guarantees uniqueness among generated keys. The LWT and the retry on clash stay in the write path, so "collision-free" does not remove the `IF NOT EXISTS`.
* Neutral, because batch size (about 1,000) trades KGS call frequency against keys lost per crash. It is configuration, not part of the decision.

## Implementation Plan

* **Affected paths**:
  * `apps/shortener_core/`: `KeySource` behaviour (`next_key/0` returning `{:ok, code} | {:error, :unavailable}`), plus the in-process generator used in tests and milestone 1.
  * `apps/kgs/`: Key DB access, batch hand-out endpoint, lease and active/standby logic, `/health`.
  * `apps/write_api/`: KGS client implementing `KeySource`, local batch pool, retry-on-clash around the insert.
  * `docker-compose.yml`: `kgs` (two instances) and the Key DB.
  * `README.md`: a KGS section that links to this ADR.
* **Dependencies**: none beyond the umbrella's existing ones. The Key DB technology is not decided here; it needs its own ADR if it is not Cassandra, since the spec lists a "Key DB" without naming one.
* **Patterns to follow**:
  * `write_api` depends only on the `KeySource` behaviour, never on KGS modules directly. Services talk over HTTP only.
  * Mark the batch used in the Key DB before returning it, so the order is write first, then respond.
  * Contract tests for `KeySource` run against every implementation.
* **Patterns to avoid**:
  * Do not derive codes from a counter or an auto-increment ID, even if scrambled.
  * Do not drop the `IF NOT EXISTS` on generated inserts, because custom aliases can clash.
  * Do not hand out a batch before it has been marked used.
* **Configuration**: `KGS_BATCH_SIZE` (default 1000), `KGS_LEASE_TTL` (default 10 s, renewed by the active node every 3 s), `WRITE_API_CLASH_RETRIES` (default 3).
* **Migration steps**: not applicable, since nothing exists yet. Milestone 1 uses the in-process `KeySource`. Milestone 2 swaps in the KGS client without changing `write_api`'s write path.

### Verification

- [ ] A shared `KeySource` contract test passes for both the in-process generator and the KGS client.
- [ ] A concurrency test with many parallel batch requests shows no key appears in two batches.
- [ ] After a KGS crash and restart, no key from a batch already marked used is handed out again.
- [ ] The standby takes over within 10 s of the active node stopping (the lease TTL), and a deposed active node cannot hand out batches.
- [ ] Under a load of 1.2k generated-code writes/s with the default batch size, KGS receives about 1.2 batch requests/s or fewer, so it stays off the per-request path.
- [ ] A generated key that clashes with an existing custom alias makes `write_api` retry with the next key and still return 201. After 3 clashes in a row it returns 503.
- [ ] With KGS down, `write_api` serves from its remaining batch, then returns 503 for generated codes, and custom aliases still return 201.
- [ ] `write_api` has no module-level dependency on the `kgs` app (checked by `mix xref` or equivalent).

## Pros and Cons of the Options

### KGS with batches

* Good, because it is collision-free among generated keys and needs no retry loop on the common path.
* Good, because codes are not sequential.
* Good, because batching keeps KGS off the per-request path and tolerates short outages.
* Bad, because it adds a service, a Key DB, and failover logic.
* Bad, because a crash wastes part of a batch.

### Counter ranges plus base62

* Good, because it is simple, and no key is wasted beyond range boundaries.
* Good, because codes are short and dense.
* Bad, because it needs a coordination service (ZooKeeper or etcd) to hand out ranges.
* Bad, because codes are sequential and guessable unless a reversible scramble is added on top, which adds its own complexity.

### Random generation plus retry on collision

* Good, because it needs no coordinator and no extra service.
* Good, because codes are not guessable.
* Bad, because the collision rate rises as the table fills, and every collision costs a failed LWT round trip at QUORUM on the write path.
* Bad, because latency becomes variable at scale.

## More Information

* Source design: [URL Shortener design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §4 (write path), §6 (KGS), §10 (failure behaviour).
* Revisit if: the Key DB becomes a bottleneck or an operational burden, if the wasted-key rate is ever measurable, or if the project stops being a showcase of the full diagram and simplicity matters more.
* Related ADRs planned: QUORUM consistency, TTL expiry. Both affect the `INSERT ... IF NOT EXISTS` used here.
* Open question: which datastore backs the Key DB. This ADR does not decide it.

