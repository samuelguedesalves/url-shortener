---
status: accepted
date: 2026-10-09
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Expire links with a TTL on the destination and never reuse codes

## Context and Problem Statement

The design replaces a cleanup service with Cassandra's `USING TTL`: links expire after 10 years by default, or at a user-set time ([design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §3, §4). A plain `INSERT ... USING TTL` expires the **whole row**, including the code. Once the row is gone, `INSERT ... IF NOT EXISTS` succeeds again for that code, so:

* a **custom alias** can be claimed by someone else, and
* a **generated key** can be handed out again once its `issued_keys` row ([ADR 0002](0002-use-cassandra-as-the-key-db-for-the-key-generation-service.md)) also expires.

Anyone still holding the old short URL would then be redirected to a stranger's destination, which is a phishing risk. How should expiry work so that a code is never given to a second owner, and what should the redirect return for an expired link?

## Decision Drivers

* **A code is never handed to a second owner.** Stated requirement.
* **No cleanup service.** Expiry should happen inside Cassandra.
* **Distinguish expired from unknown.** Users and clients get more useful behaviour from "gone" than from "never existed".
* **Compatible with the accepted ADRs.** Conditional writes at QUORUM/SERIAL ([ADR 0003](0003-use-quorum-consistency-for-cassandra-reads-and-writes.md)) and `issued_keys` ([ADR 0002](0002-use-cassandra-as-the-key-db-for-the-key-generation-service.md)).
* **Storage.** The capacity estimate (365B records, about 36.5 TB) assumed that expired data goes away.

## Considered Options

* **TTL on the destination only, permanent claim row (chosen).**
* **TTL on the whole row, codes reusable.**
* **TTL on the whole row plus a grace-period block.**
* **`expires_at` column only, no Cassandra TTL.**

## Decision Outcome

Chosen option: "**TTL on the destination only, permanent claim row**", because it is the only option that keeps a code blocked forever without a cleanup process, and it still lets Cassandra delete the bulky data by itself.

Write path, two statements, both at QUORUM (conditional ones with SERIAL, per ADR 0003):

1. **Claim the code, with no TTL:**
   `INSERT INTO urls (code, owner_id, is_custom_alias, created_at, expires_at) VALUES (?, ?, ?, ?, ?) IF NOT EXISTS`
   If not applied, the code is taken: a custom alias returns 409, and a generated key is discarded (retry rules from ADR 0001).
2. **Store the destination, with a TTL:**
   `UPDATE urls USING TTL ? SET long_url = ? WHERE code = ?`
   The TTL is the time until `expires_at` (default 10 years).

`POST /urls` returns 201 only after both succeed.

Read path:

* Row with `long_url`: redirect (302).
* Row exists, `long_url` is null: the link expired, or the write crashed between the two steps. Return **410 Gone**.
* No row: 404.
* Redis TTL for a cached destination is capped at the remaining TTL of `long_url`. A 410 is cached with the short negative TTL from ADR 0003.

Other rules:

* `issued_keys` rows (ADR 0002) are written **without** a TTL, so generated keys are never reissued.
* A crash between the two statements leaves a claimed code with no destination. It is burned, returns 410, and is never reused. This follows the same "waste, never reuse" rule as ADRs 0001 and 0002.

### Consequences

* Good, because a code is never handed to a second owner, generated or custom.
* Good, because expired links return 410 rather than 404, so clients can tell the difference.
* Good, because Cassandra still deletes the destination data by itself, with no cleanup service.
* Bad, because the table keeps one small row per code forever. I estimate tens of bytes per row against about 365 B for a full record, but this is not measured, so the 36.5 TB estimate falls and does not disappear. It should be measured before the README claims a number.
* Bad, because the write is two statements and is not atomic. The ordering (claim first, destination second) makes the failure safe, but it costs an extra round trip on every write.
* Bad, because the claim row and `issued_keys` grow without bound. Neither is ever purged, and the first signal will be storage cost.
* Neutral, because expired and burned codes both return 410, so a client cannot tell them apart. This is acceptable.

## Implementation Plan

* **Affected paths**:
  * `apps/shortener_core/`: `Url` schema (add `expires_at`, `long_url` nullable), Cassandra client functions for the claim and the destination update.
  * `apps/write_api/`: the two-step write, with the 201 only after both steps.
  * `apps/redirect_api/`: handle the 302 / 410 / 404 cases and cap the Redis TTL.
  * `apps/kgs/`: `issued_keys` is written without a TTL.
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §3, §4, §5: schema, write path and redirect cases.
  * `README.md`: explain the expiry and no-reuse rule, and link this ADR.
* **Dependencies**: none new.
* **Patterns to follow**: both statements go through the `shortener_core` client wrapper, so the consistency level stays in one place (ADR 0003).
* **Patterns to avoid**:
  * No `INSERT ... USING TTL` on `urls`, because it would expire the key.
  * No TTL on `issued_keys` rows.
  * No job or process that deletes claim rows.
  * No reordering of the two steps (destination first would leave a reusable destination without a claim).
* **Configuration**: `DEFAULT_LINK_TTL` (default 10 years), `MAX_LINK_TTL` (default 10 years, so a user cannot exceed the default).
* **Migration steps**: not applicable, since nothing exists yet.

### Verification

- [ ] After the TTL passes, `long_url` is gone and the redirect returns 410 (tested with a short TTL).
- [ ] After expiry, `INSERT ... IF NOT EXISTS` for that code (generated and custom alias) is not applied.
- [ ] A crash between the two write steps (injected failure) leaves a claimed code that returns 410, and it is never reissued.
- [ ] The cached destination's TTL never exceeds the remaining TTL of `long_url`.
- [ ] `issued_keys` rows have no TTL (checked in the schema or a test).
- [ ] An unknown code returns 404 and an expired code returns 410.
- [ ] No statement in `apps/` uses `INSERT ... USING TTL` on `urls` (grep in CI or code review).

## Pros and Cons of the Options

### TTL on the destination only, permanent claim row

* Good, because codes are never reused and no cleanup service is needed.
* Good, because it allows a distinct 410.
* Bad, because the table grows by one small row per code forever.
* Bad, because the write takes two statements.

### TTL on the whole row, codes reusable

* Good, because it is simplest, with one statement and a table that shrinks as links expire.
* Bad, because a reused code sends old short URLs to a stranger's destination.

### TTL on the whole row plus a grace-period block

* Good, because old links have time to die out before a code is reused.
* Bad, because it needs a second record per code and a mechanism to expire it, and a grace period only delays the phishing risk.

### `expires_at` column only, no Cassandra TTL

* Good, because codes are never reused and the write is one statement.
* Bad, because nothing is ever deleted, so storage grows far past the capacity estimate, and it defeats the point of using Cassandra TTL.

## More Information

* Depends on [ADR 0002](0002-use-cassandra-as-the-key-db-for-the-key-generation-service.md) and [ADR 0003](0003-use-quorum-consistency-for-cassandra-reads-and-writes.md). Both are amended by a dated note (see their More Information sections).
* Revisit if: measured storage for claim rows is too high, if a purge of very old claim rows becomes acceptable (for example after the code space is large enough to make a collision with an old link negligible), or if product requirements add a reuse policy.

