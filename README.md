# URL Shortener

An Elixir/Phoenix URL shortener built to the design in
[docs/superpowers/specs/2026-10-07-url-shortener-design.md](docs/superpowers/specs/2026-10-07-url-shortener-design.md).
Architecture decisions are recorded in [docs/adr/](docs/adr/README.md).

This README covers milestone 1 (the core path). The architecture write-up comes with milestone 6.

## Run it

Prerequisites: Docker with Compose v2, plus `curl` and `jq` for the smoke test.

```bash
docker compose up -d --build   # Cassandra, Redis, schema setup, write-api, redirect-api
./scripts/smoke.sh             # create a link, follow it, check the error cases
```

| Service | URL | Purpose |
|---|---|---|
| write-api | http://localhost:4001 | `GET /dashboard` (the web UI), `POST /urls`, `GET /urls`, `POST /auth/google`, `POST /auth/logout`, `GET /me`, `GET /health` |
| redirect-api | http://localhost:4002 | `GET /{code}`, `GET /health` |

Create a link:

```bash
curl -X POST http://localhost:4001/urls \
  -H 'content-type: application/json' \
  -d '{"url": "https://example.com/some/long/path", "custom_alias": "my-link", "ttl_seconds": 3600}'
```

`custom_alias` and `ttl_seconds` are optional. The default (and maximum) lifetime is 10 years.

| Status | Meaning |
|---|---|
| 201 | Created |
| 409 | The custom alias is taken |
| 422 | Invalid `url`, `custom_alias` or `ttl_seconds` |
| 503 | Cassandra is unavailable, or no free generated key was found |

`GET /{code}` answers 302 with `Cache-Control: no-store` (ADR 0006), 404 for an unknown code, 410 for an
expired link, and 503 when Cassandra cannot be reached.

## Dashboard

A signed-in person sees their links and creates new ones, with a chosen alias or a generated code. It is a Phoenix
LiveView served by write-api itself ([ADR 0008](docs/adr/0008-serve-the-dashboard-as-a-liveview-inside-write-api.md)):
open <http://localhost:4001/dashboard> once the stack is up. Without a Google Client ID the page shows a "login not
configured" card instead of the sign-in button.

To turn sign-in on, create a Google OAuth Client ID:

1. In the [Google Cloud Console](https://console.cloud.google.com/) open APIs and Services, Credentials.
2. Create credentials, "OAuth client ID", application type "Web application".
3. Under "Authorised JavaScript origins" add `http://localhost:4001`. No redirect URI is needed.
4. Copy `.env.example` to `.env` (git-ignored) and set `GOOGLE_CLIENT_ID=<your-client-id>.apps.googleusercontent.com`.
5. `docker compose up -d --build`, then reload the page.

Google accepts only `localhost` or HTTPS origins for sign-in, so a plain `http://192.168.x.x` address can show the page
but cannot sign in. `docker-compose.yml` also reads `SECRET_KEY_BASE`, `SESSION_SECRET`, `SESSION_TTL_SECONDS`,
`COOKIE_SECURE`, `DASHBOARD_ORIGIN` and `BASE_URL` from `.env`; each has a dev default, so an empty `.env` still boots.
The `SECRET_KEY_BASE` and `SESSION_SECRET` defaults are public, dev-only values (a known `SESSION_SECRET` lets anyone
forge a session cookie): before exposing port 4001 beyond localhost, set real random values in `.env`
(`openssl rand -base64 64 | tr -d '\n'` for `SECRET_KEY_BASE`, `openssl rand -base64 48` for `SESSION_SECRET`).

`DASHBOARD_ORIGIN` is the origin write-api is served from (the page and the API share it). It defaults to
`http://localhost:<WRITE_API_PORT>`. Write it exactly as the browser shows the origin: `scheme://host[:port]`, no
trailing slash. The LiveView websocket check normalises case and default ports, but the CORS and POST guard compares
the configured string exactly, so a mismatch makes sign-in fail with 403 `forbidden_origin` even though the page loads.

Assets (Tailwind v4 and daisyUI, vendored) are built into `apps/write_api/priv/static/assets` by the Docker build
(`mix assets.setup` and `mix assets.deploy`, run in `apps/write_api`); for local development run `mix assets.build` there.

## Dashboard API

Sign-in with Google and per-user link lists, behind the dashboard ([ADR 0007](docs/adr/0007-sign-in-with-google-and-keep-sessions-in-a-signed-cookie.md)). All on write-api.

| Endpoint | Purpose |
|---|---|
| `POST /auth/google` | Body `{"credential": "<Google ID token>"}`. Returns the user and sets the `session` cookie |
| `POST /auth/logout` | Clears the cookie. Returns 204 |
| `GET /me` | The signed-in user: `{"id", "email", "name", "picture_url"}` |
| `GET /urls` | The signed-in user's links, newest first. Query: `limit` (default 20, max 100) and `cursor` |

`GET /urls` returns `{"links": [...], "next_cursor": ...}`. Each link has `code`, `short_url`, `long_url` (null once
expired), `is_custom_alias`, `created_at`, `expires_at` and `status` (`active` or `expired`). Pass `next_cursor` back as
`cursor` for the next page.

`POST /urls` still works without signing in. With a valid session cookie it also records the signed-in user as the
owner, and its 201 body gains `is_custom_alias`.

| Status | Meaning |
|---|---|
| 401 `invalid_token` | `POST /auth/google`: the Google token failed verification (including an unverified email) |
| 401 `unauthenticated` | `GET /me` or `GET /urls` without a valid session |
| 403 `forbidden_origin` | A request other than GET, HEAD or OPTIONS carried an `Origin` other than `DASHBOARD_ORIGIN` (compared as an exact string) |
| 422 `invalid_request` | `POST /auth/google` without a `credential` |
| 422 `invalid_limit`, `invalid_cursor` | Bad `GET /urls` query |
| 503 `unavailable` | `POST /auth/google` could not reach Google or Cassandra |

The session is a signed `HttpOnly`, `SameSite=Lax` cookie. Logout clears the browser's copy only: the service keeps no
session state, so a copied cookie stays valid until it expires. Requests without an `Origin` header (curl, scripts)
are not blocked. An `OPTIONS` preflight from another origin gets a bare 204 with no CORS headers, not a 403. `auth`,
`me`, `login`, `logout` and `links` are reserved and cannot be custom aliases.

Environment variables on write-api (read in `config/runtime.exs`):

| Variable | Default | Meaning |
|---|---|---|
| `GOOGLE_CLIENT_ID` | unset | Expected audience of the Google ID token, and the Client ID the sign-in button uses. While unset, every login fails and the dashboard shows "login not configured" |
| `SESSION_SECRET` | unset | Signs the session cookie. 32 bytes or more. In prod, write-api refuses to boot without it |
| `SESSION_TTL_SECONDS` | `604800` (7 days) | Session lifetime and cookie max-age |
| `COOKIE_SECURE` | `true` | Only the string `false` drops the `Secure` flag, for plain-HTTP local runs |
| `DASHBOARD_ORIGIN` | `http://localhost:<WRITE_API_PORT>` | The origin write-api is served from. The one origin allowed by CORS (with credentials) and by the POST origin check, and the websocket origin the dashboard accepts |
| `SECRET_KEY_BASE` | unset | Signs LiveView and CSRF tokens. 64 bytes or more. In prod, write-api refuses to boot without it |
| `BASE_URL` | `http://localhost:4002` | Prefix of the `short_url` returned by the API (redirect-api's origin) |

`docker-compose.yml` defaults `SESSION_SECRET` and `SECRET_KEY_BASE` to dev-only values, `COOKIE_SECURE=false` (the
image runs over plain `http://localhost`), and `DASHBOARD_ORIGIN=http://localhost:4001`. It reads these and
`GOOGLE_CLIENT_ID` from your shell or a `.env` file (see `.env.example`):

```bash
GOOGLE_CLIENT_ID=<your-client-id>.apps.googleusercontent.com docker compose up -d --build
```

Google's signing keys are cached and refetched at most every 30 seconds (the `jwks_min_refetch_seconds` application
setting, not an environment variable). redirect-api needs none of these variables.

## Develop

Toolchain: `asdf install` reads `.tool-versions` (Erlang 27.0, Elixir 1.18.0-otp-27).

```bash
mix deps.get
mix test                                       # unit tests, no Docker needed
docker compose up -d --wait cassandra redis
INTEGRATION=1 mix test                         # also runs the tests tagged :integration
mix format --check-formatted
```
