defmodule ShortenerCore.Cassandra do
  @moduledoc """
  The shared Cassandra connection.

  ADR 0003: QUORUM is the default consistency for every statement and is set once, here.
  Call sites must not override it. Conditional statements add `serial_consistency: :serial`.
  """

  @conn __MODULE__

  @doc "Name the connection is registered under."
  def conn, do: @conn

  @doc "Child spec for the supervision tree. `opts` override the application config."
  def child_spec(opts \\ []) do
    config = Keyword.merge(config(), opts)

    xandra_opts = [
      name: @conn,
      nodes: Keyword.fetch!(config, :nodes),
      keyspace: Keyword.fetch!(config, :keyspace),
      default_consistency: :quorum
    ]

    %{id: @conn, start: {Xandra, :start_link, [xandra_opts]}}
  end

  def config, do: Application.fetch_env!(:shortener_core, :cassandra)
end
