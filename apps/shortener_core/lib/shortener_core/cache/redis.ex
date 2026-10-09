defmodule ShortenerCore.Cache.Redis do
  @moduledoc """
  Redis-backed `Cache`. Values are stored as `"U:<url>"`, `"N"` (not found) or `"G"` (gone).
  A Redis error is reported as `{:error, :unavailable}`; callers fall back to Cassandra.
  """

  @behaviour ShortenerCore.Cache

  alias ShortenerCore.Redis

  @prefix "url:"

  @impl true
  def get(code) do
    case Redix.command(Redis.conn(), ["GET", key(code)]) do
      {:ok, nil} -> :miss
      {:ok, "U:" <> url} -> {:ok, {:url, url}}
      {:ok, "N"} -> {:ok, :not_found}
      {:ok, "G"} -> {:ok, :gone}
      {:ok, _unknown} -> :miss
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def put(code, entry, ttl) when is_integer(ttl) and ttl > 0 do
    case Redix.command(Redis.conn(), ["SET", key(code), encode(entry), "EX", ttl]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def delete(code) do
    case Redix.command(Redis.conn(), ["DEL", key(code)]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp key(code), do: @prefix <> code

  defp encode({:url, url}), do: "U:" <> url
  defp encode(:not_found), do: "N"
  defp encode(:gone), do: "G"
end
