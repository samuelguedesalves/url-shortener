defmodule RedirectApi.Resolver do
  @moduledoc """
  Cache-aside lookup of a short code.

    1. Redis. A hit answers immediately; a Redis error falls through to Cassandra.
    2. On a miss, Cassandra at QUORUM (ADR 0003), then fill the cache. The destination's cache
       TTL never exceeds the link's remaining TTL (ADR 0004).

  A Cassandra error is `:unavailable` and is never cached, so an outage is not reported (or
  remembered) as "not found" (ADR 0003).
  """

  alias ShortenerCore.{Cache, Url, UrlStore}

  @code_format ~r/\A[0-9A-Za-z_-]{3,32}\z/

  @type result :: {:redirect, String.t()} | :not_found | :gone | :unavailable

  @spec resolve(String.t(), DateTime.t()) :: result()
  def resolve(code, now \\ DateTime.utc_now()) do
    # Codes shorter or longer than any we issue (aliases are 3 to 32, generated codes 7), or with other characters, cannot exist: skip the stores.
    if Regex.match?(@code_format, code) do
      case Cache.get(code) do
        {:ok, {:url, url}} -> {:redirect, url}
        {:ok, :not_found} -> :not_found
        {:ok, :gone} -> :gone
        :miss -> from_store(code, now)
        {:error, :unavailable} -> from_store(code, now)
      end
    else
      :not_found
    end
  end

  defp from_store(code, now) do
    case UrlStore.fetch(code) do
      {:ok, %Url{long_url: url, expires_at: expires_at}} when is_binary(url) ->
        cache_destination(code, url, expires_at, now)
        {:redirect, url}

      {:ok, %Url{}} ->
        _ = Cache.put(code, :gone, negative_ttl())
        :gone

      :not_found ->
        _ = Cache.put(code, :not_found, negative_ttl())
        :not_found

      {:error, :unavailable} ->
        :unavailable
    end
  end

  # The cache entry must never outlive the link (ADR 0004): with under a second left, skip it.
  defp cache_destination(code, url, expires_at, now) do
    remaining = DateTime.diff(expires_at, now, :second)

    if remaining >= 1 do
      ttl = min(remaining, Application.fetch_env!(:shortener_core, :cache_ttl))
      _ = Cache.put(code, {:url, url}, ttl)
    end

    :ok
  end

  defp negative_ttl, do: Application.fetch_env!(:shortener_core, :negative_cache_ttl)
end
