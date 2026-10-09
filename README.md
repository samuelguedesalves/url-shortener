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
| write-api | http://localhost:4001 | `POST /urls`, `GET /health` |
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

## Develop

Toolchain: `asdf install` reads `.tool-versions` (Erlang 27.0, Elixir 1.18.0-otp-27).

```bash
mix deps.get
mix test                                       # unit tests, no Docker needed
docker compose up -d --wait cassandra redis
INTEGRATION=1 mix test                         # also runs the tests tagged :integration
mix format --check-formatted
```
