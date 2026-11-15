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

config :write_api, WriteApi.Endpoint, server: false
config :redirect_api, RedirectApi.Endpoint, server: false

config :shortener_core, redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379")
