defmodule WriteApi.Auth.Jwks do
  @moduledoc """
  Caches Google's signing keys by `kid`.

  Keys are fetched lazily on the first lookup and kept for the `max_age` the fetcher reports.
  A lookup for an unknown `kid` refetches once (Google rotates keys). When a refetch fails the
  stale cache is served; only with nothing cached does a failing fetch return
  `{:error, :unavailable}`. Lookups are serialised, so at most one fetch runs at a time.

  No fetch starts sooner than `:jwks_min_refetch_seconds` (config `:write_api`, default 30)
  after the previous attempt, whatever its outcome; the first fetch is always allowed. Within
  that cooldown an unknown `kid` is `:error`, a stale cache is served as is, and with nothing
  cached the lookup is `{:error, :unavailable}`. This keeps tokens with made-up `kid`s and a
  Google outage from making every lookup wait on an outbound fetch.

  A fetcher that raises, exits or throws, or reports a `max_age` that is not a non-negative
  integer, counts as a failed fetch: the process keeps running and the cooldown still applies.
  """

  use GenServer

  require Logger

  # The fetcher's own HTTP timeouts are shorter than this.
  @call_timeout 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec get_key(String.t()) :: {:ok, JOSE.JWK.t()} | :error | {:error, :unavailable}
  def get_key(kid) do
    GenServer.call(__MODULE__, {:get_key, kid}, @call_timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_opts), do: {:ok, %{keys: nil, expires_at: nil, last_attempt: nil}}

  @impl true
  def handle_call({:get_key, kid}, _from, state) do
    {reply, state} = lookup(kid, state)
    {:reply, reply, state}
  end

  defp lookup(kid, %{keys: keys} = state) when is_map(keys) do
    cond do
      fresh?(state) and Map.has_key?(keys, kid) -> {{:ok, keys[kid]}, state}
      may_fetch?(state) -> refetch_and_lookup(kid, state)
      true -> {find(keys, kid), state}
    end
  end

  defp lookup(kid, state) do
    if may_fetch?(state),
      do: refetch_and_lookup(kid, state),
      else: {{:error, :unavailable}, state}
  end

  defp refetch_and_lookup(kid, state) do
    case refresh(state) do
      {:ok, state} -> {find(state.keys, kid), state}
      {:error, %{keys: nil} = state} -> {{:error, :unavailable}, state}
      {:error, state} -> {find(state.keys, kid), state}
    end
  end

  defp find(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, key} -> {:ok, key}
      :error -> :error
    end
  end

  defp refresh(state) do
    state = %{state | last_attempt: now()}

    with {:ok, %{keys: key_maps, max_age: max_age}}
         when is_list(key_maps) and is_integer(max_age) and max_age >= 0 <- safe_fetch(),
         {:ok, keys} <- to_jwks(key_maps) do
      {:ok, %{state | keys: keys, expires_at: state.last_attempt + max_age * 1_000}}
    else
      _ -> {:error, state}
    end
  end

  # A fetcher that raises, exits or throws counts as a failed fetch, so the process (and the
  # cooldown it holds in `last_attempt`) survives. Only the exception message is logged.
  defp safe_fetch do
    fetcher().fetch()
  rescue
    e ->
      Logger.warning("JWKS fetch raised #{inspect(e.__struct__)}: #{Exception.message(e)}")
      {:error, :fetch_raised}
  catch
    kind, _ ->
      Logger.warning("JWKS fetch failed with #{kind}")
      {:error, :fetch_raised}
  end

  defp may_fetch?(%{last_attempt: nil}), do: true
  defp may_fetch?(%{last_attempt: last}), do: now() - last >= min_refetch_ms()

  defp min_refetch_ms,
    do: Application.get_env(:write_api, :jwks_min_refetch_seconds, 30) * 1_000

  defp to_jwks(key_maps) do
    keys =
      for %{"kid" => kid, "kty" => "RSA"} = map <- key_maps, is_binary(kid), into: %{} do
        {kid, JOSE.JWK.from_map(map)}
      end

    {:ok, keys}
  rescue
    _ -> {:error, :invalid_jwks}
  end

  defp fresh?(%{expires_at: expires_at}), do: is_integer(expires_at) and now() < expires_at

  defp now do
    case Application.get_env(:write_api, :jwks_clock) do
      nil -> System.monotonic_time(:millisecond)
      clock -> clock.now_ms()
    end
  end

  defp fetcher,
    do: Application.get_env(:write_api, :jwks_fetcher, WriteApi.Auth.JwksFetcher.Httpc)
end
