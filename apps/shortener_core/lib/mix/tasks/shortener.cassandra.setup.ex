defmodule Mix.Tasks.Shortener.Cassandra.Setup do
  @shortdoc "Creates the Cassandra keyspace and tables (idempotent)"
  @moduledoc "Creates the Cassandra keyspace and tables for the URL shortener. Safe to run repeatedly."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    ShortenerCore.Cassandra.Schema.setup!()
    Mix.shell().info("Cassandra schema is ready.")
  end
end
