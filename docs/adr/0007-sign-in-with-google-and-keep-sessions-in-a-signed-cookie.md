---
status: proposed
date: 2026-11-10
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Sign in with Google and keep sessions in a signed cookie

> Note: this ADR assumes the dashboard is a separate origin. [ADR 0008](0008-serve-the-dashboard-as-a-liveview-inside-write-api.md) serves it from `write_api` itself, so the dashboard no longer uses the CORS rules below (they stay for API clients) and `DASHBOARD_ORIGIN` now means the origin `write_api` is served from.

## Context and Problem Statement

The [design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §14 put authentication out of scope. The dashboard changes that: it has to show a person their own links, so `write_api` needs to know who is calling. `Users.register_or_update` already exists in `shortener_core`, so a verified identity can become a user row. Two questions follow:

* How does a person prove who they are? Google sign-in, so the service stores no passwords.
* How does `write_api` remember them between requests? That is a session mechanism, and it decides what can be revoked, what the browser can read, and how the dashboard and API must be hosted.

## Decision Drivers

* **No password storage.** The service should not hold credentials.
* **No new infrastructure.** Milestone 1 runs Cassandra and Redis only. A session store would add a session lookup on every authenticated request.
* **Tokens out of reach of page scripts.** An XSS bug in the dashboard should not be able to read the session.
* **Anonymous creation keeps working.** `POST /urls` without a session still creates an unowned link.
* **Small scope.** Sign-in, logout and "who am I" are enough for the dashboard.

## Considered Options

* **Signed `HttpOnly` cookie holding the user id (chosen).**
* **Bearer JWT held by the SPA in JavaScript-readable storage.**
* **Server-side session store in Redis or Cassandra.**

## Decision Outcome

Chosen option: "**signed `HttpOnly` cookie holding the user id**", because it needs no session storage and keeps the credential away from page scripts. The cost is that a session cannot be revoked before it expires.

Rules:

* **Sign-in.** `POST /auth/google` takes the Google ID token as `{"credential": "..."}`. `write_api` verifies it against Google's JWKS: signature, issuer, audience equal to `GOOGLE_CLIENT_ID`, expiry, and `email_verified` must be `true`. It then calls `Users.register_or_update` and sets the `session` cookie. With `GOOGLE_CLIENT_ID` unset, every login fails closed.
* **Cookie.** `HttpOnly`, `SameSite=Lax`, `Path=/`, `Secure` unless `COOKIE_SECURE=false`, signed with `SESSION_SECRET` (at least 32 bytes; `write_api` refuses to boot in prod without it), valid for `SESSION_TTL_SECONDS` (default 7 days). It carries the user id and the time it was issued, signed but not encrypted.
* **JWKS cache.** Google's keys are cached. A refetch starts no sooner than `jwks_min_refetch_seconds` (30 by default) after the last attempt, so a token with an unknown `kid` cannot make the service call Google on every login.
* **No token storage.** The ID token is used once and discarded. It is not stored, and `credential` is in `:filter_parameters`, so Phoenix does not log it.
* **Cross-origin access.** CORS allows exactly one origin, `DASHBOARD_ORIGIN`, with credentials. Any request other than GET, HEAD or OPTIONS that carries a different `Origin` is refused with 403 `forbidden_origin`. An `OPTIONS` preflight from a different origin gets a bare 204 with no CORS headers, so the browser blocks the real request. Requests with no `Origin` header (curl, scripts) pass.
* **Reserved aliases.** `auth`, `me`, `login`, `logout` and `links` join the reserved list, so a custom alias cannot shadow a route.

### Consequences

* Good, because there is no session store: no session-store read per request and no new failure mode. `WriteApi.Plugs.FetchUser` still reads the user row (`UserStore.get/1`) on every request that carries a session cookie, including a signed-in `POST /urls`.
* Good, because page scripts cannot read the cookie, so XSS cannot steal the session.
* Good, because the service never stores a password or a Google token.
* Bad, because sessions cannot be revoked before the TTL ends. `POST /auth/logout` clears only the browser's copy; a copied cookie stays valid until it expires (7 days by default).
* Bad, because changing `SESSION_SECRET` logs everyone out, and there is no key rotation to avoid it.
* Bad, because the cookie is signed, not encrypted. The holder can read the user id and issue time in it, though not change them.
* Bad, because `SameSite=Lax` requires the dashboard and the API to share a site. Hosting them on different sites would need `SameSite=None`, plus a second look at CSRF.
* Bad, because a Google key rotation that happens inside the refetch cooldown makes valid tokens report `invalid_token` until the cooldown passes.
* Bad, because links that already use the newly reserved codes are left as they are: they keep working, but no new link can use those codes.
* Bad, because the auth endpoints have no rate limiting. The `edge` app that would provide it is not built.
* Neutral, because the Origin check is CSRF protection for browsers only. Non-browser clients are unaffected by design.

## Implementation Plan

* **Affected paths**:
  * `apps/write_api/`: `/auth/google`, `/auth/logout`, `/me`, `GET /urls`; `POST /urls` attaches the owner when a valid session is present.
  * `config/runtime.exs` and `config/config.exs`: the settings below.
  * `docker-compose.yml`: the new variables on `write-api` only.
  * [Design spec](../superpowers/specs/2026-10-07-url-shortener-design.md) §14 and `README.md`: reference this ADR.
* **Dependencies**: the `jose` library in `write_api`, for JWT and JWKS verification. Google's JWKS is fetched with OTP's `:httpc`, so no HTTP client is added. Users are stored through `shortener_core`'s existing `Users`.
* **Patterns to follow**: read the session in one plug, and require a user with a separate plug on routes that need one.
* **Patterns to avoid**: logging or persisting the Google credential; adding `Access-Control-Allow-Origin: *`; reflecting an origin that is not the configured one.
* **Configuration**: `GOOGLE_CLIENT_ID`, `SESSION_SECRET`, `SESSION_TTL_SECONDS`, `COOKIE_SECURE`, `DASHBOARD_ORIGIN`; `jwks_min_refetch_seconds` as application config.
* **Migration steps**: none. Existing links stay anonymous.

### Verification

- [ ] `GET /me` without a cookie returns 401 `unauthenticated`.
- [ ] `POST /auth/google` with an invalid or unverified-email token returns 401 `invalid_token` and sets no cookie.
- [ ] A valid login sets `HttpOnly`, `SameSite=Lax` and (unless `COOKIE_SECURE=false`) `Secure`.
- [ ] `POST /urls` with a foreign `Origin` returns 403 `forbidden_origin`.
- [ ] `write_api` fails to boot in prod without a `SESSION_SECRET` of 32 bytes or more.
- [ ] The Google credential does not appear in the request log.

## Pros and Cons of the Options

### Signed `HttpOnly` cookie holding the user id

* Good, because it is stateless and the browser sends it automatically.
* Good, because scripts cannot read it.
* Bad, because it cannot be revoked server-side, and it needs a CSRF defence (the Origin check) and a shared site.

### Bearer JWT held by the SPA in JavaScript-readable storage

* Good, because it works across sites and needs no CSRF defence, since the browser does not attach it on its own.
* Bad, because any XSS bug can read the token from storage.
* Bad, because it has the same revocation gap as the cookie, and the SPA must handle storage and expiry itself.

### Server-side session store in Redis or Cassandra

* Good, because sessions can be revoked at once and logout really ends the session.
* Bad, because it adds a store read to every authenticated request and a new way for requests to fail.
* Bad, because Redis here is an LRU cache (`allkeys-lru`) that can evict sessions, and Cassandra would need a new table with a TTL.

## More Information

* Revisit if: sessions need immediate revocation (a deny-list or a session store), the dashboard moves to a different site, or `SESSION_SECRET` rotation without logging everyone out becomes a requirement.
* The `edge` app (see the design spec) is the intended place for rate limiting on `/auth/*`.
