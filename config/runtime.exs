import Config

if config_env() != :test do
  nodes =
    "CASSANDRA_NODES"
    |> System.get_env("127.0.0.1:9042")
    |> String.split(",", trim: true)

  if length(nodes) > 1 do
    raise "CASSANDRA_NODES lists #{length(nodes)} nodes, but the client supports one node until Xandra.Cluster is adopted (planned for milestone 2). Set a single host:port."
  end

  config :shortener_core,
    cassandra: [
      nodes: nodes,
      keyspace: System.get_env("CASSANDRA_KEYSPACE", "shortener"),
      replication_factor: String.to_integer(System.get_env("CASSANDRA_REPLICATION_FACTOR", "1"))
    ],
    redis_url: System.get_env("REDIS_URL", "redis://127.0.0.1:6379")

  config :write_api,
    base_url: System.get_env("BASE_URL", "http://localhost:4002")

  config :write_api, WriteApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("WRITE_API_PORT", "4001"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))

  config :redirect_api, RedirectApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("REDIRECT_API_PORT", "4002"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))
end
