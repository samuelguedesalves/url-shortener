import Config

if config_env() != :test do
  nodes =
    "CASSANDRA_NODES"
    |> System.get_env("127.0.0.1:9042")
    |> String.split(",", trim: true)

  if length(nodes) > 1 do
    raise "CASSANDRA_NODES lists #{length(nodes)} nodes, but the client supports one node until Xandra.Cluster is adopted (planned for milestone 2). Set a single host:port."
  end

  session_ttl =
    case Integer.parse(System.get_env("SESSION_TTL_SECONDS", "")) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> 604_800
    end

  write_api_port = String.to_integer(System.get_env("WRITE_API_PORT", "4001"))

  # The public origin write_api itself is served from (the dashboard is a LiveView inside it).
  dashboard_origin =
    case System.get_env("DASHBOARD_ORIGIN", "") do
      "" -> "http://localhost:#{write_api_port}"
      origin -> origin
    end

  # In prod the key must come from the environment so a missing value fails the boot check
  # (WriteApi.Config.validate!/0); other envs keep the placeholder.
  write_api_secret_key_base =
    if config_env() == :prod,
      do: System.get_env("SECRET_KEY_BASE"),
      else: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))

  config :shortener_core,
    cassandra: [
      nodes: nodes,
      keyspace: System.get_env("CASSANDRA_KEYSPACE", "shortener"),
      replication_factor: String.to_integer(System.get_env("CASSANDRA_REPLICATION_FACTOR", "1"))
    ],
    redis_url: System.get_env("REDIS_URL", "redis://127.0.0.1:6379")

  config :write_api,
    base_url: System.get_env("BASE_URL", "http://localhost:4002"),
    google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
    # Read with safe defaults: this file runs in every service. WriteApi.Config.validate!/0
    # checks the secret at write_api boot.
    session_secret: System.get_env("SESSION_SECRET"),
    session_ttl: session_ttl,
    cookie_secure: System.get_env("COOKIE_SECURE") != "false",
    dashboard_origin: dashboard_origin

  config :write_api, WriteApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: write_api_port],
    secret_key_base: write_api_secret_key_base

  config :redirect_api, RedirectApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("REDIRECT_API_PORT", "4002"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))
end
