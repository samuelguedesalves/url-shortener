defmodule ShortenerCore.Cache.Memory do
  @moduledoc """
  In-memory `Cache` for unit tests. Start it with `start_supervised!(ShortenerCore.Cache.Memory)`.
  It records the TTL passed to `put/3` so tests can assert on it; entries never expire.
  """

  @behaviour ShortenerCore.Cache

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "TTL in seconds that `put/3` was last called with for `code`, or `nil`."
  def ttl(code) do
    Agent.get(__MODULE__, fn entries ->
      case Map.fetch(entries, code) do
        {:ok, {_entry, ttl}} -> ttl
        :error -> nil
      end
    end)
  end

  @impl true
  def get(code) do
    Agent.get(__MODULE__, fn entries ->
      case Map.fetch(entries, code) do
        {:ok, {entry, _ttl}} -> {:ok, entry}
        :error -> :miss
      end
    end)
  end

  @impl true
  def put(code, entry, ttl), do: Agent.update(__MODULE__, &Map.put(&1, code, {entry, ttl}))

  @impl true
  def delete(code), do: Agent.update(__MODULE__, &Map.delete(&1, code))
end
