defmodule ShortenerCore.UrlStore do
  @moduledoc """
  Storage for short links. A link is written in two steps (ADR 0004):

    1. `claim/1` reserves the code permanently (no TTL).
    2. `put_destination/3` stores `long_url` with a TTL.

  Implementation chosen by `config :shortener_core, :url_store`.
  """

  alias ShortenerCore.Url

  @callback claim(Url.t()) :: :ok | {:error, :taken | :unavailable}
  @callback put_destination(
              code :: String.t(),
              long_url :: String.t(),
              ttl_seconds :: pos_integer()
            ) ::
              :ok | {:error, :unavailable}
  @callback fetch(code :: String.t()) :: {:ok, Url.t()} | :not_found | {:error, :unavailable}

  def claim(%Url{} = url), do: impl().claim(url)
  def put_destination(code, long_url, ttl), do: impl().put_destination(code, long_url, ttl)
  def fetch(code), do: impl().fetch(code)

  defp impl, do: Application.fetch_env!(:shortener_core, :url_store)
end
