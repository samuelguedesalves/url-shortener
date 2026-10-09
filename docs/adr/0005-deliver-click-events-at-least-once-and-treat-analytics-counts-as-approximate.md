---
status: accepted
date: 2026-10-09
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Deliver click events at-least-once and treat analytics counts as approximate

## Context and Problem Statement

Every redirect publishes a click event, `{code, ts, referrer, country, user_agent_class}`, to a Kafka topic partitioned by `code`. The `click_consumer` app (a Broadway pipeline) batches the events and writes hourly aggregates to a ClickHouse `SummingMergeTree` table, and `analytics_api` serves `GET /stats/{code}` from it ([design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §5, §7). The system targets about 11.6k redirects/s.

Two rules from the spec pull against exact counts:

* The redirect never waits on Kafka and still succeeds when Kafka is down (§5, §10), so some events are dropped.
* The consumer commits offsets only after a successful insert, so a crash between the insert and the commit replays the batch.

The delivery guarantee decides how offsets are committed, what the stats API promises, and what the README may claim. How exact do click counts need to be, and which delivery guarantee follows?

## Decision Drivers

* **The redirect path comes first.** Latency and availability of `GET /{code}` outweigh analytics accuracy.
* **Simple pipeline.** Milestone 4 should not need an event-ID scheme or an outbox.
* **Honest numbers.** Whatever the error is, the stats API and the README must say so.
* **Scale.** About 11.6k events/s at peak, so per-event deduplication state would be large.

## Considered Options

* **At-least-once, approximate counts (chosen).**
* **At-least-once plus deduplication on event ID.**
* **Exact counts.**

## Decision Outcome

Chosen option: "**At-least-once, approximate counts**", because it keeps the redirect off the Kafka critical path and the pipeline simple, and the cost, a small and bounded error in click counts, is acceptable for analytics on a portfolio project.

Rules:

* **Producer:** the redirect publishes asynchronously and never waits. If the publish fails (Kafka down), the event is dropped and a `click_events_dropped` metric is incremented.
* **Consumer commit:** `click_consumer` commits offsets only after the ClickHouse insert succeeds. A failed insert is retried with backoff and never skipped.
* **Malformed events:** an event that cannot be decoded or validated is logged, counted in `click_events_malformed`, and skipped, so one bad event cannot block a partition.
* **Batching:** batch size and flush interval are configuration (defaults 1,000 events or 5 s).
* **Stats API:** `GET /stats/{code}` states that counts are approximate, in the response (a field such as `"approximate": true`) and in its documentation.

### Where the error comes from

* **Under-count:** events dropped at the producer while Kafka is down. Visible in `click_events_dropped`.
* **Over-count:** a batch replayed after a crash between the insert and the offset commit. `SummingMergeTree` adds the duplicates. The error per crash is bounded by one in-flight batch (up to the configured batch size) per consumer instance.
* Both are accepted. The ADR makes no claim about the size of the error beyond these bounds.

### Consequences

* Good, because the redirect never depends on Kafka, so a Kafka outage doesn't affect redirects.
* Good, because the pipeline needs no event IDs, deduplication state or outbox.
* Good, because offsets are committed only after a durable insert, so no event is silently lost on the consumer side.
* Bad, because counts can be both too low (dropped events) and too high (replays), and the two don't cancel in any predictable way.
* Bad, because a poison event is skipped, so a systematic decode bug would silently lose events until someone watches `click_events_malformed`.
* Neutral, because the analytics are for trends and totals, not billing. If a use case needs exact counts, that is a new decision.

## Implementation Plan

* **Affected paths**:
  * `apps/redirect_api/`: async publish to Kafka off the request path, drop metric.
  * `apps/click_consumer/`: Broadway pipeline (batch, insert, commit after success), malformed-event handling, metrics.
  * `apps/analytics_api/`: add the approximate-counts field and documentation to the stats response.
  * `docker-compose.yml`: create the click topic (partitioned by `code`), and the ClickHouse table.
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §5, §7, §10: reference this ADR.
  * `README.md`: explain the guarantee and the two error sources, and link this ADR.
* **Dependencies**: Broadway and the Kafka and ClickHouse clients named in the spec. Pin versions when `apps/click_consumer` is scaffolded.
* **Patterns to follow**: the publish is fire-and-forget, wrapped so that a failure only increments a metric.
* **Patterns to avoid**:
  * No blocking or retrying the publish on the redirect path.
  * No offset commit before the insert succeeds.
  * No infinite retry on a malformed event.
  * No claim in docs or UI that counts are exact.
* **Configuration**: `CLICK_BATCH_SIZE` (default 1000), `CLICK_BATCH_TIMEOUT_MS` (default 5000).
* **Migration steps**: not applicable, since nothing exists yet.

### Verification

- [ ] With Kafka stopped, a redirect still returns 302 and `click_events_dropped` increases.
- [ ] Killing the consumer between the insert and the offset commit, then restarting, replays the batch, and a test asserts the over-count is at most one batch.
- [ ] A failed ClickHouse insert does not advance the offset, and the batch is retried.
- [ ] A malformed event is skipped and counted in `click_events_malformed`, and later events in the same partition are processed.
- [ ] The stats response says counts are approximate, and the README documents both error sources.
- [ ] No code path on the redirect request waits for the Kafka publish (code review or a test with a slow broker showing unchanged redirect latency).

## Pros and Cons of the Options

### At-least-once, approximate counts

* Good, because it is the simplest pipeline and keeps the redirect independent of Kafka.
* Good, because the error is bounded and observable through metrics.
* Bad, because counts are not exact in either direction.

### At-least-once plus deduplication on event ID

* Good, because replays no longer inflate counts.
* Bad, because every event needs an ID and the consumer or ClickHouse needs deduplication state or a different table design (for example `ReplacingMergeTree` or insert deduplication tokens), which costs storage at 11.6k events/s.
* Bad, because it still can't fix under-counting from dropped events.

### Exact counts

* Good, because totals could be trusted.
* Bad, because the redirect must not drop events, which needs a local buffer or outbox, and that bends the rule that the redirect never waits on Kafka.
* Bad, because it still needs deduplication on the consumer side.

## More Information

* Independent of ADRs 0001 to 0004. Related ADR planned: 302 vs 301, because a 302 is what makes every click reach the redirect and be counted.
* Revisit if: the dropped or malformed counters show a meaningful share of traffic, if stats are ever used for billing or quotas, or if the replay over-count is large enough to confuse users (then option 2 is the first step).

