# Dashboard API: Requirements

Date: 2026-11-09
Branch: `feat/visual-dashboard`
Parent spec: [URL shortener design](2026-10-07-url-shortener-design.md) (milestone 5, dashboard). This document covers the **backend/API half only**. The dashboard UI gets its own document after this one is approved.

Marking convention: **[user]** was decided by the user. **[my call]** is the author's choice, open to override.

## 1. Intent

A signed-in user opens the dashboard, sees the links they own, and creates a new one. A new link gets either an alias the user chose or an auto-generated code. **[user]**

Today the backend has the pieces (Google user registration, an owner on the link, a "list by owner" store function) but none of them is reachable over HTTP, and nobody can prove who they are. This work exposes them as an API a browser can use.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. Sign in with Google and stay signed in across page loads.
- G2. List the signed-in user's links, newest first.
- G3. Create a link owned by the signed-in user, with a custom alias or an auto-generated code.
- G4. Keep anonymous `POST /urls` working exactly as today (smoke test, existing clients). **[my call]**

**Non-goals (this iteration)** **[my call, except where noted]**
- Editing, deleting or disabling a link.
- Click counts or any analytics field. The analytics pipeline does not exist yet (ADR 0005); the link JSON must not include a placeholder count.
- An "is this alias free?" pre-check endpoint. A 409 on create is the only signal.
- Claiming links that were created anonymously earlier.
- Rate limiting of the new endpoints (the `edge` app is not built; revisit when it is).
- Account deletion, other login providers, roles.

**Anti-goals** (a failure even if it technically works)
- Accepting an unverified Google token, or trusting the `sub`/`email` sent by the browser.
- A user ever seeing another user's links.
- Storing the Google ID token.
- Changing the redirect path (`redirect_api`) in any way.

## 3. Constraints

- Elixir/Phoenix umbrella as is. New routes live in `write_api` (port 4001), the only app that writes. `redirect_api` is untouched.
- Reuse `ShortenerCore.Users.register_or_update/2`, `UrlStore.list_by_owner/2` (to be extended) and `WriteApi.Shortener.create/2` (already accepts `owner_id:`).
- Cassandra schema changes go through `mix shortener.cassandra.setup`; none are expected (`urls_by_user` already clusters by `created_at DESC, code`).
- All Google/network access sits behind a behaviour so tests run with a fake, like the existing store doubles. `mix test` must still need no Docker or network.
- Error bodies keep the existing shape `{"error": "<slug>"}`.

## 4. Authentication and session

**Flow** **[my call]**: the browser obtains a Google ID token (Google Identity Services) and posts it to the API. The API verifies it, registers or updates the user, and starts a session. Sessions are a signed, `HttpOnly` cookie holding the user id, so the server stays stateless.

| Property | Requirement |
|---|---|
| Token checks | RS256 signature against Google's published keys (cached per their cache headers), `iss` is `accounts.google.com` or `https://accounts.google.com`, `aud` equals `GOOGLE_CLIENT_ID`, not expired. |
| Email policy | `email_verified` must be `true`, else 401. **[my call]** |
| Cookie | `HttpOnly`, `SameSite=Lax`, `Path=/`, signed. `Secure` is controlled by an explicit `COOKIE_SECURE` setting (default `true`), **not** by `MIX_ENV`. The Docker image runs `MIX_ENV=prod` over plain `http://localhost`, and Safari drops `Secure` cookies there, so `docker-compose.yml` sets `COOKIE_SECURE=false`. **[my call]** |
| Lifetime | 7 days fixed, no sliding refresh. Configurable. **[my call]** |
| Logout | Clears the cookie. Stateless sessions cannot be revoked server-side before expiry; this is accepted. |
| Secret | Signing secret from env, used by `write_api` only. `write_api` must **fail to boot** in `prod` if it is unset (today `SECRET_KEY_BASE` has a hard-coded default that must not be usable for sessions). `redirect_api` does not use sessions and its config stays untouched. `docker-compose.yml` supplies a dev secret so the existing stack and smoke test keep working. **[my call]** |

**Browser access** **[my call]**: CORS with a single allowed origin from `DASHBOARD_ORIGIN`, credentials allowed, `OPTIONS` preflight answered. Requests carrying an `Origin` that is not the allowed one are rejected for state-changing methods (CSRF guard; the JSON-only parser already blocks form posts). Requests with **no** `Origin` header (curl, the smoke test) are allowed. The dashboard and API are assumed to share a *site* (e.g. both `localhost`, or subdomains of one domain). A cross-site deployment would need `SameSite=None` and is out of scope.

> Note: the dashboard UI is now served by `write_api` itself (LiveView, same origin), so the dashboard no longer relies on this CORS behaviour; it stays for API clients. `DASHBOARD_ORIGIN` then means the origin `write_api` is served from. See [ADR 0008](../../adr/0008-serve-the-dashboard-as-a-liveview-inside-write-api.md).

## 5. Endpoints

All on `write_api`. JSON in, JSON out.

### `POST /auth/google`
- Body: `{"credential": "<google id token>"}`.
- 200: sets the session cookie, returns the `User` body below.
- 401 `{"error":"invalid_token"}`: any verification failure, unverified email, or expired token.
- 422 `{"error":"invalid_request"}`: missing/blank `credential`.
- 503 `{"error":"unavailable"}`: Cassandra down, or Google keys unreachable with none cached.
- Calling it again for the same Google account reuses the same user id and refreshes profile fields.

### `POST /auth/logout`
- 204, clears the cookie. Succeeds even with no session.

### `GET /me`
- 200: `{"id","email","name","picture_url"}` for the session user.
- 401 `{"error":"unauthenticated"}` with no/invalid/expired session. The dashboard uses this on load to decide between login screen and list.

### `GET /urls`  (new, auth required)
- Query: `limit` (default 20, min 1, max 100), `cursor` (opaque, optional).
- 200: `{"links": [Link], "next_cursor": string | null}`, newest first by creation time. `next_cursor` is `null` on the last page. **[my call]** cursor pagination over `(created_at, code)`.
- Only links whose `owner_id` is the session user.
- 401 `unauthenticated`; 422 `{"error":"invalid_limit"}` / `{"error":"invalid_cursor"}`; 503 `unavailable`.

### `POST /urls`  (existing, extended)
- Request and validation unchanged: `url`, optional `custom_alias`, optional `ttl_seconds`; the same 201/409/422/503 responses.
- **New:** when a valid session cookie is present, the link is created with `owner_id` set to the session user. Without a session it is created anonymously, as today. A *bad or expired* cookie is treated as no session, not as an error. **[my call]**
- 201 body stays `{"code","short_url","expires_at"}` so existing clients and the smoke test keep working, and gains `"is_custom_alias"` (additive).
- Reserved aliases are extended with `auth`, `me`, `login`, `logout`, `links`. **[my call]** The write and redirect hosts differ today, but the short domain could later front both. The extension applies to **everyone**, anonymous creates included (the reservation is about routing, not about who calls). This is the one deliberate difference from "anonymous behaves as today"; a test pins it.

### Shapes

```
User: { "id": "uuid", "email": "...", "name": "...", "picture_url": "..." | null }

Link: {
  "code": "aB3xY9Z",
  "short_url": "http://host/aB3xY9Z",
  "long_url": "https://..." | null,
  "is_custom_alias": true | false,
  "created_at": "2026-11-09T12:00:00Z",
  "expires_at": "2036-11-09T12:00:00Z",
  "status": "active" | "expired"
}
```

- A session whose user no longer exists is treated as no session (401 on `/me` and `/urls`). **[my call]**
- `status` is derived server-side: `expired` when `expires_at` has passed or `long_url` is gone (a claimed code with no destination counts as expired too). **[my call]** Because expiry deletes the destination (ADR 0004), an expired link has `long_url: null`; the dashboard cannot show where it used to point. Expired links stay in the list.
- Timestamps are ISO 8601 UTC.

## 6. Configuration (new env vars)

| Var | Purpose |
|---|---|
| `GOOGLE_CLIENT_ID` | Expected `aud`. Required in prod. |
| `SESSION_SECRET` (or the existing `SECRET_KEY_BASE`, builder's choice) | Cookie signing. No default in prod. |
| `SESSION_TTL_SECONDS` | Default 604800. |
| `COOKIE_SECURE` | Default `true`; `false` in compose/dev over plain http. |
| `DASHBOARD_ORIGIN` | Allowed CORS origin. |

`docker-compose.yml` and the README gain these.

## 7. Acceptance criteria

1. With a fake verifier: valid credential → cookie + `User`; the same credential twice → same `id`.
2. Invalid signature/audience/issuer/expiry or `email_verified: false` → 401 and no user row written.
3. `GET /urls` with no cookie → 401; with user A's cookie returns only A's links; two users never see each other's.
4. Pagination: 25 links, `limit=10` gives 10, 10, 5 with correct cursors, no duplicates or gaps, newest first. Links created in the same millisecond are not skipped (hence `code` in the cursor).
5. Create with an alias while signed in: appears in the user's list with `is_custom_alias: true`. Create without: a 7-char code with `is_custom_alias: false`. Duplicate alias → 409.
6. Anonymous `POST /urls` behaves as before (existing tests and `scripts/smoke.sh` pass unchanged), except that the newly reserved aliases now return 422 `invalid_alias`.
7. An expired link shows `status: "expired"` and `long_url: null`.
8. CORS: preflight from `DASHBOARD_ORIGIN` succeeds with credentials; from any other origin gets no CORS headers; a state-changing request from another origin is rejected.
9. `mix format --check-formatted` and `mix test` pass; contract tests cover any new `UrlStore` callback on both the in-memory and Cassandra implementations.

## 8. Left to the builder

- Library for JWT/JWKS verification (new dependency) and how the keys are cached.
- Cookie mechanism (`Plug.Session` cookie store vs a signed `Phoenix.Token` cookie).
- Cursor encoding, and how `list_by_owner` is extended (`after` argument vs new function) and whether it batches the `urls` lookups.
- Whether session lookup is a plug in the router pipeline.

## 9. Follow-ups this implies

- **ADR** for sign-in and session design. None exists, and it overrides the parent spec's §14 ("authentication and user accounts ... out of scope"), which needs a one-line update.
- The dashboard UI document (screens, stack, states) comes next and depends on these endpoints.
