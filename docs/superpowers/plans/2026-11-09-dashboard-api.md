# Dashboard API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a browser sign in with Google, list the signed-in user's links, and create links they own (custom alias or generated code).

**Architecture:** All new routes live in `write_api`. A Google ID token is verified behind a swappable `Verifier` behaviour, then `ShortenerCore.Users.register_or_update/2` registers the user and a signed `HttpOnly` cookie carries the session. `UrlStore.list_by_owner` gains cursor paging. `redirect_api` is not touched.

**Tech Stack:** Elixir 1.18, Phoenix 1.7 umbrella, Cassandra (Xandra), ExUnit. New dependency: `jose` (JWT/JWKS). JWKS is fetched with OTP's `:httpc`.

**Spec:** `docs/superpowers/specs/2026-11-09-dashboard-api-requirements.md` (parent: `docs/superpowers/specs/2026-10-07-url-shortener-design.md`). Read both.

## Global Constraints

- Run tasks **in order, one at a time**: several tasks edit `router.ex`, `config/*.exs` and `doubles.ex`.
- Commit messages end with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Error bodies are `{"error": "<slug>"}`. Slugs: `unauthenticated`, `invalid_token`, `invalid_request`, `invalid_limit`, `invalid_cursor`, `forbidden_origin`, plus the existing `alias_taken`, `invalid_url`, `invalid_alias`, `invalid_ttl`, `unavailable`.
- `redirect_api` code and config stay untouched. `mix test` needs no Docker or network; Cassandra tests run only with `INTEGRATION=1` and `docker compose up -d cassandra redis`.
- Session cookie: name `session`, `HttpOnly`, `SameSite=Lax`, `Path=/`, signed, `Secure` only when config `cookie_secure` is true. Default lifetime 604800 s.
- Google ID token checks: RS256, `iss` in `["accounts.google.com", "https://accounts.google.com"]`, `aud` equals `google_client_id`, not expired, `email_verified == true`. JWKS URL `https://www.googleapis.com/oauth2/v3/certs`.
- Pagination: `limit` default 20, min 1, max 100. Order newest first; ties on `created_at` ordered by `code` ascending.
- Reserved aliases become: `health urls stats metrics dashboard api admin static assets auth me login logout links` (case-insensitive).
- Config keys under `config :write_api` (each task adds the ones it uses to `config/config.exs`, `config/test.exs`, `config/runtime.exs` and, for env vars, `docker-compose.yml`): `verifier`, `google_client_id`, `jwks_fetcher`, `session_secret`, `session_ttl`, `cookie_secure`, `dashboard_origin`, `require_secrets`.
- `mix format --check-formatted` must pass at every commit.

## Review Focus

Inputs the spec implies but no acceptance criterion pins. Each has a test in the named task.

1. A tampered, expired, or other-secret cookie on `POST /urls` creates an anonymous link instead of failing, and on `/me` gives 401 (Task 4, Task 7).
2. A garbage, truncated, or foreign-user cursor never leaks other users' links; bad `limit` values (`0`, `101`, `abc`, `1.5`) give 422 (Task 2, Task 6).
3. Alias reservation ignores case: `Me`, `LOGIN` give 422 (Task 7).
4. Many links with the same `created_at` page without gaps or duplicates (Task 1).
5. Google rotates keys (unknown `kid`) or the JWKS endpoint is down: refetch once, serve a stale cache, and give 503 only when nothing is cached (Task 3).

---

### Task 1: Cursor paging in `UrlStore.list_by_owner`

**Files:**
- Modify: `apps/shortener_core/lib/shortener_core/url_store.ex`, `url_store/memory.ex`, `url_store/cassandra.ex`
- Modify: `apps/shortener_core/test/support/url_store_contract.ex`
- Modify: `apps/write_api/test/support/doubles.ex` (`DownStore`, `DestinationFailsStore`)

**Interfaces:**
- Produces: `ShortenerCore.UrlStore.list_by_owner(owner_id :: String.t(), limit :: pos_integer(), after :: nil | {DateTime.t(), String.t()} \\ nil) :: {:ok, [Url.t()]} | {:error, :unavailable}`. `after` is the `{created_at, code}` of the last link of the previous page; the result holds links strictly after it in order (`created_at` desc, `code` asc). The callback and both stores take 3 arguments; the facade keeps the 2-argument form through the default.

- [ ] **Step 1: Write failing contract tests** in `url_store_contract.ex`, switching existing calls to the 3-argument form `list_by_owner(owner, 50, nil)` and adding:
  - `"list_by_owner pages with an after cursor"`: 5 links at distinct times, `limit 2` then `after: {last.created_at, last.code}` repeatedly yields the codes in order with no overlap, then `{:ok, []}`.
  - `"list_by_owner pages through links sharing one created_at"`: 5 links with identical `created_at`; paging with `limit 2` returns all 5 exactly once, ordered by `code` ascending.
  - `"after is scoped to the owner"`: another owner's links never appear.
- [ ] **Step 2: Run to confirm failure:** `cd apps/shortener_core && mix test test/shortener_core/url_store/memory_test.exs`. Expect failures (arity).
- [ ] **Step 3: Implement.** Callback and facade as in Interfaces. `Memory`: filter the sorted list to links strictly after `after`, then `Enum.take(limit)`. `Cassandra`: two queries, first `SELECT code FROM urls_by_user WHERE owner_id = ? AND created_at = ? AND code > ? LIMIT ?` (same-timestamp remainder), then, only if that returned fewer than `limit`, `... AND created_at < ? LIMIT ?` for the rest; concatenate, keep the existing `fetch_all/1`. With `after == nil` run the existing query. Update the two doubles to arity 3 (`DestinationFailsStore` delegates to `Memory`).
- [ ] **Step 4: Run:** `mix test` from the repo root passes. With Docker up, also `INTEGRATION=1 mix test apps/shortener_core/test/shortener_core/url_store/cassandra_test.exs` passes. If Docker is not available, say so in the report.
- [ ] **Step 5: Commit** `feat(core): page list_by_owner with an after cursor`.

---

### Task 2: Link view and the `Links.page/2` listing

**Files:**
- Create: `apps/write_api/lib/write_api/cursor.ex`, `link_view.ex`, `links.ex`
- Test: `apps/write_api/test/write_api/cursor_test.exs`, `links_test.exs`

**Interfaces:**
- Consumes: `UrlStore.list_by_owner/3` (Task 1).
- Produces:
  - `WriteApi.Cursor.encode(DateTime.t(), String.t()) :: String.t()` (url-safe base64, no padding, of `"<unix_ms>:<code>"`) and `decode(String.t()) :: {:ok, {DateTime.t(), String.t()}} | :error`; `:error` for anything malformed, including a code that fails `^[0-9A-Za-z_-]{3,32}$`.
  - `WriteApi.LinkView.to_map(Url.t(), now :: DateTime.t()) :: map()` with keys `code, short_url, long_url, is_custom_alias, created_at, expires_at, status`. `status` is `"expired"` when `long_url` is nil or `expires_at` is not after `now`, else `"active"`. `short_url` is `base_url <> "/" <> code`.
  - `WriteApi.Links.page(owner_id :: String.t(), query :: map()) :: {:ok, %{links: [map()], next_cursor: String.t() | nil}} | {:error, :invalid_limit | :invalid_cursor | :unavailable}`. `query` is the raw string-keyed query map. Asks the store for `limit + 1` to know whether a next page exists; `next_cursor` encodes the last returned link, or is `nil`.

- [ ] **Step 1: Write failing tests.** `cursor_test`: round-trip; `decode("%%%")`, `decode("")`, a valid base64 of `"abc"` and of `"1:../x"` all return `:error`. `links_test` (Memory store): 25 links, limit 10 → 10/10/5 with `next_cursor` nil on the last page, no duplicates; a link without destination has `status: "expired"` and `long_url: nil`; `limit` of `"0"`, `"101"`, `"abc"`, `"1.5"` → `{:error, :invalid_limit}`; `cursor: "garbage"` → `{:error, :invalid_cursor}`; a cursor taken from user A's page used by user B never returns A's links; `DownStore` → `{:error, :unavailable}`.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/cursor_test.exs test/write_api/links_test.exs`.
- [ ] **Step 3: Implement** the three modules per Interfaces. `limit` must match `^\d+$` exactly before `Integer.parse`.
- [ ] **Step 4: Run** the same command; expect PASS, then `mix test` at the root.
- [ ] **Step 5: Commit** `feat(write_api): cursor and link view for listing`.

---

### Task 3: Google ID token verifier

**Files:**
- Modify: `apps/write_api/mix.exs` (add `{:jose, "~> 1.11"}`, `:inets` and `:ssl` to `extra_applications`), `mix.lock`
- Create: `apps/write_api/lib/write_api/auth/verifier.ex`, `auth/google_verifier.ex`, `auth/jwks.ex`, `auth/jwks_fetcher.ex`
- Modify: `apps/write_api/lib/write_api/application.ex` (supervise `WriteApi.Auth.Jwks`), `apps/write_api/test/support/doubles.ex`, `config/config.exs`, `config/test.exs`, `config/runtime.exs`
- Test: `apps/write_api/test/write_api/auth/google_verifier_test.exs`

**Interfaces:**
- Produces:
  - Behaviour `WriteApi.Auth.Verifier`: `verify(credential :: String.t()) :: {:ok, claims :: map()} | {:error, :invalid_token | :unavailable}`. Facade `WriteApi.Auth.Verifier.verify/1` calls the module in config `:verifier` (default `WriteApi.Auth.GoogleVerifier`; in test `WriteApi.Doubles.FakeVerifier`, which returns the claims registered for the credential string in an Agent, else `{:error, :invalid_token}`; add `FakeVerifier.allow(credential, claims)` to the doubles).
  - Behaviour `WriteApi.Auth.JwksFetcher`: `fetch() :: {:ok, %{keys: [map()], max_age: non_neg_integer()}} | {:error, term()}`. Default implementation uses `:httpc` against the Google URL and reads `max-age` from `cache-control`. Config `:jwks_fetcher` picks it.
  - `WriteApi.Auth.Jwks` (GenServer): `get_key(kid) :: {:ok, JOSE.JWK.t()} | :error | {:error, :unavailable}`. Caches keys until `max_age` expires; on an unknown `kid` refetches once; if a refetch fails it serves the stale cache; with no cache and a failing fetch returns `{:error, :unavailable}`.

- [ ] **Step 1: Write failing tests** with an RSA key from `JOSE.JWK.generate_key({:rsa, 2048})` and a stub `JwksFetcher` in the test file (module reading the key set from `Application` env). Cases: valid token returns claims; wrong signature, wrong `aud`, wrong `iss`, expired, `email_verified: false` (and a missing claim) each return `{:error, :invalid_token}`; non-JWT garbage and `alg: none` return `{:error, :invalid_token}`; unknown `kid` refetches once and succeeds after the stub is updated; fetcher failing with a warm cache still verifies; fetcher failing with no cache returns `{:error, :unavailable}`.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/auth/google_verifier_test.exs`.
- [ ] **Step 3: Implement** per Interfaces (`mix deps.get` first). `GoogleVerifier.verify/2` takes an optional `now` for tests. Config `google_client_id` from env `GOOGLE_CLIENT_ID` (nil when unset; verification then fails closed with `invalid_token`).
- [ ] **Step 4: Run** the test and the full `mix test`; add the compiled warnings check `mix compile --warnings-as-errors`.
- [ ] **Step 5: Commit** `feat(write_api): verify Google ID tokens`.

---

### Task 4: Session cookie and request plugs

**Files:**
- Create: `apps/write_api/lib/write_api/session.ex`, `plugs/fetch_user.ex`, `plugs/require_user.ex`, `config.ex`
- Modify: `apps/write_api/lib/write_api/application.ex` (call `WriteApi.Config.validate!/0` at start), `config/config.exs`, `config/test.exs` (a fixed `session_secret` of 64 bytes, `cookie_secure: false`), `config/prod.exs` (`require_secrets: true`), `config/runtime.exs`
- Test: `apps/write_api/test/write_api/session_test.exs`, `plugs_test.exs`, `config_test.exs`

**Interfaces:**
- Consumes: `ShortenerCore.UserStore.get/1`.
- Produces:
  - `WriteApi.Session.issue(conn, user_id :: String.t(), opts \\ []) :: Plug.Conn.t()` (`opts[:now]` a `DateTime`), `clear(conn) :: Plug.Conn.t()`, `user_id(conn, now \\ DateTime.utc_now()) :: {:ok, String.t()} | :none`. Anything invalid, tampered, expired or signed with another secret is `:none`.
  - Plug `WriteApi.Plugs.FetchUser`: sets `conn.assigns.current_user` to a `%User{}` or `nil`. No cookie, bad cookie, or a user id that no longer exists gives `nil`; `UserStore` `{:error, :unavailable}` halts with 503 `{"error":"unavailable"}`.
  - Plug `WriteApi.Plugs.RequireUser`: halts with 401 `{"error":"unauthenticated"}` when `current_user` is nil.
  - `WriteApi.Config.validate!/0`: raises when `require_secrets` is true and `session_secret` is missing or shorter than 32 bytes.
  - Config: env `SESSION_SECRET`, `SESSION_TTL_SECONDS` (default 604800), `COOKIE_SECURE` (default `true`; only the string `"false"` turns it off).

- [ ] **Step 1: Write failing tests.** `session_test`: issue then read round-trips; flipped byte → `:none`; cookie signed with a different secret → `:none`; cookie older than `session_ttl` (using `now:`) → `:none`; `clear` expires the cookie; the `Set-Cookie` of `issue` contains `HttpOnly` and `SameSite=Lax`, and `secure` follows `cookie_secure`. `plugs_test`: no cookie → nil user; valid cookie for a user in `UserStore.Memory` → that user; cookie for a deleted user → nil; a down user store → 503; `RequireUser` → 401. `config_test`: `validate!` raises with `require_secrets: true` and a nil or short secret, passes otherwise.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/session_test.exs test/write_api/plugs_test.exs test/write_api/config_test.exs`.
- [ ] **Step 3: Implement.** Mechanism is the implementer's choice (`Phoenix.Token` in a plain signed cookie is the expected one). Keep `redirect_api` config untouched: the secret check lives in `WriteApi.Application.start/2`, not in `runtime.exs`, because `runtime.exs` is evaluated by every service.
- [ ] **Step 4: Run** the tests and the full `mix test`.
- [ ] **Step 5: Commit** `feat(write_api): signed session cookie and user plugs`.

---

### Task 5: Auth endpoints

**Files:**
- Create: `apps/write_api/lib/write_api/controllers/auth_controller.ex`, `me_controller.ex`, `apps/write_api/lib/write_api/user_view.ex`
- Modify: `apps/write_api/lib/write_api/router.ex`, `apps/write_api/lib/write_api/error_json.ex` (only if needed)
- Test: `apps/write_api/test/write_api/auth_controller_test.exs`

**Interfaces:**
- Consumes: `Verifier.verify/1` (Task 3), `ShortenerCore.Users.register_or_update/2`, `Session.issue/clear`, plugs (Task 4).
- Produces routes: `POST /auth/google`, `POST /auth/logout`, `GET /me`. User JSON is `{"id","email","name","picture_url"}`; add `WriteApi.UserView.to_map(User.t()) :: map()` for it. The router gets a pipeline running `FetchUser`, reused by Tasks 6 and 7.

- [ ] **Step 1: Write failing tests** with `FakeVerifier`: valid credential → 200, a `session` cookie, the user body, user stored; same credential twice → same `id`; `{"credential":"bad"}` → 401 `invalid_token` and no user stored; missing, blank or non-string `credential` → 422 `invalid_request`; verifier `:unavailable` → 503; down user store → 503; `GET /me` with the cookie from login → 200; without a cookie, with a tampered cookie, and after logout → 401 `unauthenticated`; logout without a session → 204.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/auth_controller_test.exs`.
- [ ] **Step 3: Implement** the controllers and routes. `/auth/logout` and `/auth/google` do not require a session.
- [ ] **Step 4: Run** the test and the full `mix test`.
- [ ] **Step 5: Commit** `feat(write_api): Google sign-in, logout and /me`.

---

### Task 6: `GET /urls`

**Files:**
- Modify: `apps/write_api/lib/write_api/controllers/url_controller.ex`, `router.ex`
- Test: `apps/write_api/test/write_api/url_list_test.exs`

**Interfaces:**
- Consumes: `Links.page/2` (Task 2), `RequireUser` and the session pipeline (Tasks 4, 5).
- Produces: `GET /urls` → 200 `{"links": [...], "next_cursor": ...}` for `conn.assigns.current_user.id`. Errors map `:invalid_limit` and `:invalid_cursor` to 422 with those slugs, `:unavailable` to 503.

- [ ] **Step 1: Write failing tests:** no session → 401; two logged-in users each see only their own links; 25 links paged 10/10/5 by following `next_cursor`; `limit=0|101|abc|1.5` → 422 `invalid_limit`; `cursor=garbage` → 422 `invalid_cursor`; user A's cursor sent by user B returns only B's links; an expired link appears with `status: "expired"` and `long_url: null`; down store → 503; a generated and a custom alias link carry the right `is_custom_alias`.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/url_list_test.exs`.
- [ ] **Step 3: Implement** `UrlController.index/2` and the route, inside the pipeline with `RequireUser`.
- [ ] **Step 4: Run** the test and the full `mix test`.
- [ ] **Step 5: Commit** `feat(write_api): list the signed-in user's links`.

---

### Task 7: Owned creation, `is_custom_alias`, new reserved aliases

**Files:**
- Modify: `apps/write_api/lib/write_api/controllers/url_controller.ex`, `shortener.ex`, `link_params.ex`, `router.ex`
- Modify: `apps/write_api/test/write_api/url_controller_test.exs`, `shortener_test.exs`

**Interfaces:**
- Consumes: the session pipeline (Task 5), `Shortener.create(params, owner_id: id)`.
- Produces: `POST /urls` runs behind `FetchUser` but not `RequireUser`; with a user it passes `owner_id:`. The 201 body becomes `{"code","short_url","expires_at","is_custom_alias"}`; update `Shortener.link()` type and `finish/4` accordingly. Reserved list per Global Constraints.

- [ ] **Step 1: Write failing tests:** a signed-in create appears in that user's `GET /urls` with the right `is_custom_alias` for both alias and generated cases; an anonymous create is created with `owner_id: nil` and listed for nobody; a tampered or expired cookie creates an anonymous link with 201; duplicate alias while signed in → 409; each of `auth me login logout links`, and `Me` and `LOGIN`, → 422 `invalid_alias`, with and without a session. Existing tests that compare the exact 201 body get the new key.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test`.
- [ ] **Step 3: Implement** per Interfaces. A store `:unavailable` during `FetchUser` already yields 503 (Task 4); a bad cookie is not an error.
- [ ] **Step 4: Run** `mix test` at the root. With the stack up, `./scripts/smoke.sh` still prints `OK` (skip and say so if Docker is unavailable).
- [ ] **Step 5: Commit** `feat(write_api): owned links, is_custom_alias and reserved auth paths`.

---

### Task 8: CORS and origin guard

**Files:**
- Create: `apps/write_api/lib/write_api/plugs/cors.ex`
- Modify: `apps/write_api/lib/write_api/endpoint.ex` (plug before `Plug.Parsers`), `config/config.exs`, `config/test.exs` (`dashboard_origin: "http://dashboard.test"`), `config/runtime.exs` (env `DASHBOARD_ORIGIN`)
- Test: `apps/write_api/test/write_api/cors_test.exs`

**Interfaces:**
- Produces `WriteApi.Plugs.Cors`, behaviour:
  - `OPTIONS` preflight from the allowed origin → 204 with `access-control-allow-origin: <origin>`, `access-control-allow-credentials: true`, `access-control-allow-methods: GET, POST, OPTIONS`, `access-control-allow-headers: content-type`, `access-control-max-age: 600`, `vary: origin`. Preflight from another origin → 204 with no CORS headers.
  - Other requests from the allowed origin get the allow-origin, credentials and `vary` headers. From another origin on a GET they pass through without CORS headers.
  - `POST` carrying an `Origin` that is not the allowed one (or any `Origin` when `dashboard_origin` is nil) → 403 `{"error":"forbidden_origin"}`, halted before the body is read. No `Origin` header (curl, the smoke script) always passes.

- [ ] **Step 1: Write failing tests** for each bullet, including `POST /urls` from a foreign origin returning 403 and creating nothing, and `POST /urls` with no `Origin` still returning 201.
- [ ] **Step 2: Run to confirm failure:** `cd apps/write_api && mix test test/write_api/cors_test.exs`.
- [ ] **Step 3: Implement** the plug and wire it into the endpoint.
- [ ] **Step 4: Run** the test and the full `mix test`.
- [ ] **Step 5: Commit** `feat(write_api): CORS for the dashboard origin and a CSRF origin guard`.

---

### Task 9: Compose, README and ADR

**Files:**
- Modify: `docker-compose.yml` (`write-api` only: `GOOGLE_CLIENT_ID`, `SESSION_SECRET` set to a clearly-dev value of 64+ characters, `COOKIE_SECURE: "false"`, `DASHBOARD_ORIGIN: http://localhost:5173`; do not add them to the shared `service_env` anchor, so `redirect-api` and `migrate` stay unchanged), `README.md` (new endpoints, env vars)
- Create: `docs/adr/0007-sign-in-with-google-and-keep-sessions-in-a-signed-cookie.md` (same front matter and MADR sections as ADR 0006: decision, drivers, options considered such as bearer JWT vs cookie, consequences including "no server-side revocation")
- Modify: `docs/adr/README.md` (add the line), `docs/superpowers/specs/2026-10-07-url-shortener-design.md` §14 (one line saying sign-in with Google is now in scope, see ADR 0007)

**Interfaces:** none.

- [ ] **Step 1: Make the edits above.** Do not paste a real Google client id; leave `GOOGLE_CLIENT_ID` as `${GOOGLE_CLIENT_ID:-}`.
- [ ] **Step 2: Verify.** `docker compose config` parses. With Docker: `docker compose up -d --build`, `./scripts/smoke.sh` prints `OK`, `curl -s localhost:4001/me` returns `{"error":"unauthenticated"}`, `redirect-api` still starts without any of the new variables. Without Docker, run `docker compose config` only and say what was skipped.
- [ ] **Step 3: Commit** `docs: document the dashboard API, env vars and ADR 0007`.
