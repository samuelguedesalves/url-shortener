defmodule WriteApi.Doubles do
  @moduledoc "Test doubles for the failure cases the in-memory fakes cannot produce."

  defmodule ScriptedKeySource do
    @moduledoc "Returns the keys it was started with, in order. Start with `start_supervised!({ScriptedKeySource, keys})`."
    @behaviour ShortenerCore.KeySource
    use Agent

    def start_link(keys), do: Agent.start_link(fn -> keys end, name: __MODULE__)

    @impl true
    def next_key do
      Agent.get_and_update(__MODULE__, fn
        [key | rest] -> {{:ok, key}, rest}
        [] -> {{:error, :unavailable}, []}
      end)
    end
  end

  defmodule DownStore do
    @moduledoc "Cassandra is unreachable."
    @behaviour ShortenerCore.UrlStore
    @impl true
    def claim(_url), do: {:error, :unavailable}
    @impl true
    def put_destination(_code, _url, _ttl), do: {:error, :unavailable}
    @impl true
    def fetch(_code), do: {:error, :unavailable}
    @impl true
    def list_by_owner(_owner_id, _limit), do: {:error, :unavailable}
  end

  defmodule DestinationFailsStore do
    @moduledoc "The claim works, the second write step fails: a crash between the two steps."
    @behaviour ShortenerCore.UrlStore
    alias ShortenerCore.UrlStore.Memory
    @impl true
    def claim(url), do: Memory.claim(url)
    @impl true
    def put_destination(_code, _url, _ttl), do: {:error, :unavailable}
    @impl true
    def fetch(code), do: Memory.fetch(code)
    @impl true
    def list_by_owner(owner_id, limit), do: Memory.list_by_owner(owner_id, limit)
  end

  defmodule DownCache do
    @moduledoc "Redis is unreachable."
    @behaviour ShortenerCore.Cache
    @impl true
    def get(_code), do: {:error, :unavailable}
    @impl true
    def put(_code, _entry, _ttl), do: {:error, :unavailable}
    @impl true
    def delete(_code), do: {:error, :unavailable}
  end

  @doc "Swaps an application env value for the duration of the test."
  def swap_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(app, key, old) end)
  end
end
