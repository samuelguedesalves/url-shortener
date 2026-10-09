defmodule ShortenerCore.KeySource do
  @moduledoc """
  Where `write_api` gets unique codes from (ADR 0001).

  The implementation is chosen by `config :shortener_core, :key_source`. Milestone 1 uses
  `ShortenerCore.KeySource.InProcess`; milestone 2 adds a KGS client behind the same behaviour.
  """

  @callback next_key() :: {:ok, String.t()} | {:error, :unavailable}

  @spec next_key() :: {:ok, String.t()} | {:error, :unavailable}
  def next_key, do: impl().next_key()

  defp impl, do: Application.fetch_env!(:shortener_core, :key_source)
end
