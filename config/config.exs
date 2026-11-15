import Config

config :logger, :default_formatter, metadata: [:request_id]

config :shortener_core,
  url_store: ShortenerCore.UrlStore.Cassandra,
  user_store: ShortenerCore.UserStore.Cassandra,
  cache: ShortenerCore.Cache.Redis,
  key_source: ShortenerCore.KeySource.InProcess,
  start_clients: true,
  cassandra: [nodes: ["127.0.0.1:9042"], keyspace: "shortener", replication_factor: 1],
  redis_url: "redis://127.0.0.1:6379",
  # Milliseconds. Client-side timeout on every Cassandra call, so a stuck node gives 503 (ADR 0003).
  cassandra_timeout: 5_000,
  # Seconds. 10 years is the default and the maximum link lifetime (ADR 0004).
  default_link_ttl: 315_360_000,
  max_link_ttl: 315_360_000,
  # Upper bound for a cached destination; the real TTL is also capped by the link's remaining TTL.
  cache_ttl: 3_600,
  # Short TTL for 404 and 410 entries (ADR 0003).
  negative_cache_ttl: 30

# Phoenix logs each request's parameters at :debug. Keep secrets out of those lines: the Google
# ID token posted to /auth/google is a bearer credential. Applies to every endpoint in the umbrella.
config :phoenix, :filter_parameters, ["password", "credential"]

config :write_api, WriteApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  server: true,
  render_errors: [formats: [json: WriteApi.ErrorJSON], layout: false],
  # Salt for the LiveView session tokens, which are signed with the endpoint's secret_key_base.
  live_view: [signing_salt: "write_api live view"]

config :write_api,
  base_url: "http://localhost:4002",
  # Attempts to find an unclaimed generated key before returning 503 (ADR 0001).
  max_key_attempts: 3,
  # Sign-in: verifies Google ID tokens against Google's JWKS. The client id comes from
  # GOOGLE_CLIENT_ID in runtime.exs; while unset every token is rejected.
  verifier: WriteApi.Auth.GoogleVerifier,
  jwks_fetcher: WriteApi.Auth.JwksFetcher.Httpc,
  # Minimum seconds between JWKS fetch attempts (unknown kids, refreshes after a failure).
  jwks_min_refetch_seconds: 30,
  google_client_id: nil,
  # Session cookie (WriteApi.Session). SESSION_SECRET comes from runtime.exs and signs the cookie;
  # WriteApi.Config.validate!/0 requires it at boot when require_secrets is true (prod only).
  session_secret: nil,
  # Seconds a session stays valid; also the cookie's max-age.
  session_ttl: 604_800,
  # The cookie carries `Secure`. Only COOKIE_SECURE=false turns it off, for plain-HTTP local runs.
  cookie_secure: true,
  require_secrets: false,
  # The origin write_api is served from (the dashboard is a LiveView inside it): the one browser
  # origin allowed to call the API with credentials (CORS), to POST to it, and to open the dashboard
  # websocket. runtime.exs sets it from DASHBOARD_ORIGIN, defaulting to http://localhost:<port>, so
  # this nil is only the compile-time default. With nil, no CORS headers are sent and every POST
  # that carries an Origin header is refused.
  dashboard_origin: nil

config :redirect_api, RedirectApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  server: true,
  render_errors: [formats: [json: RedirectApi.ErrorJSON], layout: false]

# Dashboard assets (`mix assets.build` in apps/write_api). The versions are required.
config :esbuild,
  version: "0.25.4",
  write_api: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/write_api/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.0",
  write_api: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/write_api", __DIR__)
  ]

import_config "#{config_env()}.exs"
