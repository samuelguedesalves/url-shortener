defmodule ShortenerCore.Cassandra.Schema do
  @moduledoc """
  Idempotent schema setup for the `shortener` keyspace. Run with `mix shortener.cassandra.setup`.

  The Key DB tables (`kgs` keyspace, ADR 0002) are added in milestone 2.
  """

  @keyspace_format ~r/\A[a-z][a-z0-9_]{0,47}\z/
  @attempts 30
  @retry_delay_ms 2_000

  @doc "CQL statements that create the keyspace and tables."
  @spec statements(keyspace :: String.t(), replication_factor :: pos_integer()) :: [String.t()]
  def statements(keyspace, replication_factor) do
    if not Regex.match?(@keyspace_format, keyspace) do
      raise ArgumentError, "invalid keyspace name: #{inspect(keyspace)}"
    end

    if not (is_integer(replication_factor) and replication_factor > 0) do
      raise ArgumentError, "invalid replication factor: #{inspect(replication_factor)}"
    end

    [
      """
      CREATE KEYSPACE IF NOT EXISTS #{keyspace}
      WITH replication = {'class': 'SimpleStrategy', 'replication_factor': #{replication_factor}}
      """,
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.urls (
        code text PRIMARY KEY,
        long_url text,
        owner_id text,
        is_custom_alias boolean,
        created_at timestamp,
        expires_at timestamp
      )
      """,
      # An owner's links, newest first. Holds only the code: the destination and its TTL stay
      # in `urls`, which is the single source of truth.
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.urls_by_user (
        owner_id text,
        created_at timestamp,
        code text,
        PRIMARY KEY ((owner_id), created_at, code)
      ) WITH CLUSTERING ORDER BY (created_at DESC, code ASC)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.users (
        id uuid PRIMARY KEY,
        google_id text,
        email text,
        name text,
        picture_url text,
        email_verified boolean,
        created_at timestamp,
        updated_at timestamp
      )
      """,
      # Lookup table for sign-in: Google `sub` to internal id, written first with IF NOT EXISTS.
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.users_by_google_id (
        google_id text PRIMARY KEY,
        user_id uuid
      )
      """
    ]
  end

  @doc """
  Creates the keyspace and tables, retrying while Cassandra starts up.
  Uses its own connection because the application connection needs the keyspace to exist.
  """
  @spec setup!(keyword()) :: :ok
  def setup!(config \\ ShortenerCore.Cassandra.config()) do
    {:ok, _} = Application.ensure_all_started(:xandra)
    {:ok, conn} = Xandra.start_link(nodes: Keyword.fetch!(config, :nodes))

    try do
      statements(Keyword.fetch!(config, :keyspace), Keyword.fetch!(config, :replication_factor))
      |> Enum.each(&execute_with_retry!(conn, &1, @attempts))
    after
      GenServer.stop(conn)
    end
  end

  defp execute_with_retry!(conn, statement, attempts_left) do
    case Xandra.execute(conn, statement, []) do
      {:ok, _} ->
        :ok

      {:error, error} when attempts_left > 1 ->
        IO.puts("Cassandra not ready (#{Exception.message(error)}), retrying...")
        Process.sleep(@retry_delay_ms)
        execute_with_retry!(conn, statement, attempts_left - 1)

      {:error, error} ->
        raise "Cassandra schema setup failed: #{Exception.message(error)}"
    end
  end
end
