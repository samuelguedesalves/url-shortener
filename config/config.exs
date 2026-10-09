import Config

config :logger, :default_formatter, metadata: [:request_id]

config :shortener_core,
  url_store: ShortenerCore.UrlStore.Cassandra,
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

config :write_api, WriteApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  server: true,
  render_errors: [formats: [json: WriteApi.ErrorJSON], layout: false]

config :write_api,
  base_url: "http://localhost:4002",
  # Attempts to find an unclaimed generated key before returning 503 (ADR 0001).
  max_key_attempts: 3

config :redirect_api, RedirectApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  server: true,
  render_errors: [formats: [json: RedirectApi.ErrorJSON], layout: false]

import_config "#{config_env()}.exs"
