defmodule ShortenerCore.UrlStore.Memory do
  @moduledoc """
  In-memory `UrlStore` for unit tests. Start it with `start_supervised!(ShortenerCore.UrlStore.Memory)`.
  TTL expiry is checked on read against the monotonic clock, like Cassandra's.
  """

  @behaviour ShortenerCore.UrlStore

  use Agent

  alias ShortenerCore.Url

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{rows: %{}, owners: %{}} end, name: __MODULE__)
  end

  @impl true
  def claim(%Url{code: code} = url) do
    Agent.get_and_update(__MODULE__, fn %{rows: rows, owners: owners} = state ->
      if Map.has_key?(rows, code) do
        {{:error, :taken}, state}
      else
        rows = Map.put(rows, code, %{url: url, destination: nil})
        {:ok, %{state | rows: rows, owners: index(owners, url)}}
      end
    end)
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    deadline = System.monotonic_time(:millisecond) + ttl * 1_000

    Agent.update(__MODULE__, fn %{rows: rows} = state ->
      rows = Map.update!(rows, code, &%{&1 | destination: {long_url, deadline}})
      %{state | rows: rows}
    end)
  end

  @impl true
  def fetch(code) do
    Agent.get(__MODULE__, fn %{rows: rows} ->
      case Map.fetch(rows, code) do
        :error -> :not_found
        {:ok, row} -> {:ok, to_url(row)}
      end
    end)
  end

  @impl true
  def list_by_owner(owner_id, limit) do
    Agent.get(__MODULE__, fn %{rows: rows, owners: owners} ->
      urls =
        owners
        |> Map.get(owner_id, [])
        |> Enum.map(&to_url(Map.fetch!(rows, &1)))
        |> Enum.sort(&newest_first?/2)
        |> Enum.take(limit)

      {:ok, urls}
    end)
  end

  defp index(owners, %Url{owner_id: nil}), do: owners

  defp index(owners, %Url{owner_id: owner_id, code: code}),
    do: Map.update(owners, owner_id, [code], &[code | &1])

  defp newest_first?(a, b) do
    case DateTime.compare(a.created_at, b.created_at) do
      :gt -> true
      :lt -> false
      :eq -> a.code <= b.code
    end
  end

  defp to_url(%{url: url, destination: destination}), do: %Url{url | long_url: live(destination)}

  defp live(nil), do: nil

  defp live({long_url, deadline}) do
    if System.monotonic_time(:millisecond) < deadline, do: long_url, else: nil
  end
end
