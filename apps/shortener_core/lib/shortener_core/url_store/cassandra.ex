defmodule ShortenerCore.UrlStore.Cassandra do
  @moduledoc """
  `UrlStore` on Cassandra.

  ADR 0004: `claim/1` is an `INSERT ... IF NOT EXISTS` with no TTL, `put_destination/3` is an
  `UPDATE ... USING TTL` on `long_url` only. ADR 0003: all statements run at QUORUM (the
  connection default); the conditional claim adds serial consistency SERIAL.
  """

  @behaviour ShortenerCore.UrlStore

  alias ShortenerCore.{Cassandra, Url}

  @claim """
  INSERT INTO urls (code, owner_id, is_custom_alias, created_at, expires_at)
  VALUES (?, ?, ?, ?, ?) IF NOT EXISTS
  """

  @put_destination "UPDATE urls USING TTL ? SET long_url = ? WHERE code = ?"

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
          [%{"[applied]" => true}] -> :ok
          _ -> {:error, :taken}
        end

      {:error, _} ->
        # A timed-out claim may or may not have applied; the caller treats the code as burned.
        {:error, :unavailable}
    end
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    case execute(@put_destination, [ttl, long_url, code], []) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
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

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp execute(statement, params, opts) do
    with {:ok, prepared} <- Xandra.prepare(Cassandra.conn(), statement) do
      Xandra.execute(Cassandra.conn(), prepared, params, opts)
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
