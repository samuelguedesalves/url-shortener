defmodule ShortenerCore.UrlStore.Cassandra do
  @moduledoc """
  `UrlStore` on Cassandra.

  ADR 0004: `claim/1` is an `INSERT ... IF NOT EXISTS` with no TTL, `put_destination/3` is an
  `UPDATE ... USING TTL` on `long_url` only. ADR 0003: all statements run at QUORUM (the
  connection default); the conditional claim adds serial consistency SERIAL.

  An owned link is also indexed in `urls_by_user`. That is a second statement, because a
  conditional write cannot share a batch with a write to another partition. It runs only
  after the claim applied, so the index never lists a code another link holds.
  """

  @behaviour ShortenerCore.UrlStore

  require Logger

  alias ShortenerCore.{Cassandra, Url}

  @claim """
  INSERT INTO urls (code, owner_id, is_custom_alias, created_at, expires_at)
  VALUES (?, ?, ?, ?, ?) IF NOT EXISTS
  """

  @put_destination "UPDATE urls USING TTL ? SET long_url = ? WHERE code = ?"

  @index_owner "INSERT INTO urls_by_user (owner_id, created_at, code) VALUES (?, ?, ?)"

  @list_codes "SELECT code FROM urls_by_user WHERE owner_id = ? LIMIT ?"

  @fetch """
  SELECT code, long_url, owner_id, is_custom_alias, created_at, expires_at
  FROM urls WHERE code = ?
  """

  @impl true
  def claim(%Url{} = url) do
    params = [url.code, url.owner_id, url.is_custom_alias, url.created_at, url.expires_at]

    case execute(@claim, params, serial_consistency: :serial) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [%{"[applied]" => true}] -> index_owner(url)
          _ -> {:error, :taken}
        end

      {:error, error} ->
        # A timed-out claim may or may not have applied; the caller treats the code as burned.
        log_error("claim", url.code, error)
    end
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    case execute(@put_destination, [ttl, long_url, code], []) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        log_error("put_destination", code, error)
    end
  end

  @impl true
  def fetch(code) do
    case execute(@fetch, [code], []) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [] -> :not_found
          [row] -> {:ok, to_url(row)}
        end

      {:error, error} ->
        log_error("fetch", code, error)
    end
  end

  @impl true
  def list_by_owner(owner_id, limit) when is_integer(limit) and limit > 0 do
    case execute(@list_codes, [owner_id, limit], []) do
      {:ok, page} -> page |> Enum.map(& &1["code"]) |> fetch_all()
      {:error, error} -> log_error("list_by_owner", "owner " <> owner_id, error)
    end
  end

  defp index_owner(%Url{owner_id: nil}), do: :ok

  defp index_owner(%Url{owner_id: owner_id, created_at: created_at, code: code}) do
    case execute(@index_owner, [owner_id, created_at, code], []) do
      {:ok, _} -> :ok
      {:error, error} -> log_error("index_owner", code, error)
    end
  end

  # `urls` is the source of truth, so each listed code is read from it. Every read is bounded by
  # the Cassandra timeout, hence no extra task timeout. Order is the index order.
  defp fetch_all(codes) do
    codes
    |> Task.async_stream(&fetch/1, max_concurrency: 10, timeout: :infinity)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, url}}, {:ok, urls} -> {:cont, {:ok, [url | urls]}}
      {:ok, :not_found}, acc -> {:cont, acc}
      {:ok, {:error, :unavailable} = error}, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      error -> error
    end
  end

  defp log_error(operation, code, error) do
    Logger.warning("UrlStore.Cassandra #{operation} failed for #{code}: #{error_message(error)}")

    {:error, :unavailable}
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp execute(statement, params, opts) do
    # ADR 0003: bound every call so a frozen or partitioned node yields 503, not a hang.
    timeout = Application.fetch_env!(:shortener_core, :cassandra_timeout)

    with {:ok, prepared} <- Xandra.prepare(Cassandra.conn(), statement, timeout: timeout) do
      Xandra.execute(Cassandra.conn(), prepared, params, [timeout: timeout] ++ opts)
    end
  end

  defp to_url(row) do
    %Url{
      code: row["code"],
      long_url: row["long_url"],
      owner_id: row["owner_id"],
      is_custom_alias: row["is_custom_alias"],
      created_at: row["created_at"],
      expires_at: row["expires_at"]
    }
  end
end
