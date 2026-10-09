defmodule ShortenerCore.Cache do
  @moduledoc """
  Cache-aside cache for redirects. One entry per code, either a destination or a negative result:

    * `{:url, long_url}` - redirect target
    * `:not_found` - no such code (404)
    * `:gone` - the link expired (410)

  Implementation chosen by `config :shortener_core, :cache`.
  """

  @type entry :: {:url, String.t()} | :not_found | :gone

  @callback get(code :: String.t()) :: {:ok, entry()} | :miss | {:error, :unavailable}
  @callback put(code :: String.t(), entry(), ttl_seconds :: pos_integer()) ::
              :ok | {:error, :unavailable}
  @callback delete(code :: String.t()) :: :ok | {:error, :unavailable}

  def get(code), do: impl().get(code)
  def put(code, entry, ttl), do: impl().put(code, entry, ttl)
  def delete(code), do: impl().delete(code)

  defp impl, do: Application.fetch_env!(:shortener_core, :cache)
end
