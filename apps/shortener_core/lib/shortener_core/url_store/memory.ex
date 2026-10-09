defmodule ShortenerCore.UrlStore.Memory do
  @moduledoc """
  In-memory `UrlStore` for unit tests. Start it with `start_supervised!(ShortenerCore.UrlStore.Memory)`.
  TTL expiry is checked on read against the monotonic clock, like Cassandra's.
  """

  @behaviour ShortenerCore.UrlStore

  use Agent

  alias ShortenerCore.Url

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def claim(%Url{code: code} = url) do
    Agent.get_and_update(__MODULE__, fn rows ->
      if Map.has_key?(rows, code) do
        {{:error, :taken}, rows}
      else
        {:ok, Map.put(rows, code, %{url: url, destination: nil})}
      end
    end)
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    deadline = System.monotonic_time(:millisecond) + ttl * 1_000

    Agent.update(__MODULE__, fn rows ->
      Map.update!(rows, code, &%{&1 | destination: {long_url, deadline}})
    end)
  end

  @impl true
  def fetch(code) do
    Agent.get(__MODULE__, fn rows ->
      case Map.fetch(rows, code) do
        :error ->
          :not_found

        {:ok, %{url: url, destination: destination}} ->
          {:ok, %Url{url | long_url: live(destination)}}
      end
    end)
  end

  defp live(nil), do: nil

  defp live({long_url, deadline}) do
    if System.monotonic_time(:millisecond) < deadline, do: long_url, else: nil
  end
end
