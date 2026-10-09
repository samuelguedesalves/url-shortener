# Integration tests need Cassandra and Redis (docker compose up -d cassandra redis).
# Run them with: INTEGRATION=1 mix test
exclude = if System.get_env("INTEGRATION") == "1", do: [], else: [:integration]

ExUnit.start(exclude: exclude)
