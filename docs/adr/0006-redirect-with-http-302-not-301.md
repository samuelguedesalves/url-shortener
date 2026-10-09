---
status: accepted
date: 2026-10-09
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Redirect with HTTP 302, not 301

## Context and Problem Statement

`GET /{code}` answers with an HTTP redirect to the long URL ([design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §5). The status code decides whether clients may cache the redirect:

* **301 Moved Permanently** is cacheable. Browsers and intermediaries may serve repeat clicks without contacting the service.
* **302 Found** is not cached unless the response says so, so every click reaches the service.

[ADR 0005](0005-deliver-click-events-at-least-once-and-treat-analytics-counts-as-approximate.md) counts clicks by publishing an event from the redirect. [ADR 0004](0004-expire-links-with-a-ttl-on-the-destination-and-never-reuse-codes.md) makes expired links return 410. Both only work if requests actually reach `redirect_api`. The redirect endpoint is built in milestone 1, so the status code and cache headers have to be fixed first. Which status code should it use, and what cache headers go with it?

## Decision Drivers

* **Every click reaches the service,** so analytics can count it (ADR 0005).
* **Expiry takes effect immediately.** A cached redirect must not keep serving an expired link (ADR 0004).
* **Load.** About 11.6k reads/s, mostly absorbed by the Redis cache (spec §1).

## Considered Options

* **302 Found with `Cache-Control: no-store` (chosen).**
* **301 Moved Permanently.**
* **307 Temporary Redirect.**

## Decision Outcome

Chosen option: "**302 Found with `Cache-Control: no-store`**", because it is the only option here that guarantees every click reaches the service. The cost is higher load, which the Redis cache is there to absorb.

Rules:

* A successful lookup returns **302** with a `Location` header and `Cache-Control: no-store`. The explicit header stops clients that apply heuristic caching to a bare 302.
* **404** and **410** responses also carry `Cache-Control: no-store`, so an expired or unknown link is not cached by a client.

### Consequences

* Good, because every click reaches `redirect_api` and produces a click event, so analytics see all of them.
* Good, because an expired or changed link takes effect on the next request, with no stale browser cache.
* Bad, because every repeat click is served by the service. There is no browser-side offload, and the Redis cache and Cassandra carry all of the read load.
* Bad, because a 301 would let clients and intermediaries absorb repeat traffic for popular links. That offload is given up deliberately.
* Neutral, because 302 and 307 behave the same for GET, so the choice between them has no effect here.

## Implementation Plan

* **Affected paths**:
  * `apps/redirect_api/`: the controller returns 302, `Location`, and `Cache-Control: no-store`. The 404 and 410 responses also set `no-store`.
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §5: reference this ADR.
  * The k6 load test (spec §12): measure the redirect path with no client caching, which is the case this ADR chooses.
  * `README.md`: explain 302 vs 301 and link this ADR.
* **Dependencies**: none.
* **Patterns to follow**: set the status and headers in one place in `redirect_api`, so all three response types share the `no-store` rule.
* **Patterns to avoid**:
  * No 301 or 308 anywhere in the redirect path.
  * No `max-age` or other cache hint on redirect, 404 or 410 responses.
* **Configuration**: none. The status code and headers are not configurable.
* **Migration steps**: not applicable, since nothing exists yet.

### Verification

- [ ] `GET /{code}` for a live link returns 302 with the correct `Location` and `Cache-Control: no-store`.
- [ ] Two requests for the same code from one client both reach the service and both produce a click event.
- [ ] After a link expires, the next request returns 410, and the response carries `no-store`.
- [ ] A 404 response carries `no-store`.
- [ ] No 301 or 308 status appears in `apps/redirect_api` (grep in CI or code review).

## Pros and Cons of the Options

### 302 Found with `Cache-Control: no-store`

* Good, because every click is counted and expiry is immediate.
* Bad, because there is no client-side offload, so the service carries all repeat traffic.

### 301 Moved Permanently

* Good, because clients and intermediaries cache it, which cuts load and latency for repeat visits.
* Bad, because cached clicks never reach the service, so analytics under-count.
* Bad, because an expired or changed link can keep redirecting from a cache, and it is hard to undo once cached.

### 307 Temporary Redirect

* Good, because it is explicitly temporary and preserves the request method.
* Neutral, because for GET it behaves like 302.
* Bad, because it offers nothing here over 302, and 302 is the conventional choice for link shorteners.

## More Information

* Supports [ADR 0004](0004-expire-links-with-a-ttl-on-the-destination-and-never-reuse-codes.md) and [ADR 0005](0005-deliver-click-events-at-least-once-and-treat-analytics-counts-as-approximate.md).
* Revisit if: analytics are dropped from the product (then 301 becomes an option for offload), or if redirect load grows past what the Redis cache and Cassandra can serve, in which case a short `max-age` on 302 is the first step, accepting that those clicks go uncounted.

