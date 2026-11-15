import Config

config :logger, level: :warning

config :shortener_core,
  url_store: ShortenerCore.UrlStore.Memory,
  user_store: ShortenerCore.UserStore.Memory,
  cache: ShortenerCore.Cache.Memory,
  start_clients: false,
  cassandra: [
    nodes: [System.get_env("CASSANDRA_TEST_NODE", "127.0.0.1:9042")],
    keyspace: "shortener_test",
    replication_factor: 1
  ]

# runtime.exs does not run in test; LiveView signs its session tokens with this key.
config :write_api, WriteApi.Endpoint,
  server: false,
  secret_key_base: String.duplicate("t", 64)

config :write_api,
  verifier: WriteApi.Doubles.FakeVerifier,
  jwks_fetcher: WriteApi.Doubles.StubJwksFetcher,
  # No cooldown, so each test's refetches happen; the cooldown tests set their own.
  jwks_min_refetch_seconds: 0,
  session_secret: String.duplicate("t", 64),
  session_ttl: 604_800,
  cookie_secure: false,
  require_secrets: false,
  dashboard_origin: "http://dashboard.test"

config :redirect_api, RedirectApi.Endpoint, server: false

config :shortener_core, redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379")
