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
    def list_by_owner(_owner_id, _limit, _after), do: {:error, :unavailable}
  end

  defmodule DownUserStore do
    @moduledoc "Cassandra is unreachable, seen from the user store."
    @behaviour ShortenerCore.UserStore
    @impl true
    def get(_id), do: {:error, :unavailable}
    @impl true
    def get_by_google_id(_google_id), do: {:error, :unavailable}
    @impl true
    def claim_google_id(_google_id, _user_id), do: {:error, :unavailable}
    @impl true
    def put(_user), do: {:error, :unavailable}
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
    def list_by_owner(owner_id, limit, after_cursor),
      do: Memory.list_by_owner(owner_id, limit, after_cursor)
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

  defmodule FakeVerifier do
    @moduledoc """
    Accepts only credentials registered with `allow/2` and returns their claims; anything else
    is `{:error, :invalid_token}`. The registry lives for the calling test.
    """
    @behaviour WriteApi.Auth.Verifier
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @doc "Makes `credential` verify to `claims` for the rest of the test."
    def allow(credential, claims) do
      unless Process.whereis(__MODULE__), do: ExUnit.Callbacks.start_supervised!(__MODULE__)
      Agent.update(__MODULE__, &Map.put(&1, credential, claims))
    end

    @impl true
    def verify(credential) do
      case Process.whereis(__MODULE__) && Agent.get(__MODULE__, &Map.fetch(&1, credential)) do
        {:ok, claims} -> {:ok, claims}
        _ -> {:error, :invalid_token}
      end
    end
  end

  defmodule UnavailableVerifier do
    @moduledoc "Google's key set cannot be fetched."
    @behaviour WriteApi.Auth.Verifier
    @impl true
    def verify(_credential), do: {:error, :unavailable}
  end

  defmodule StubJwksFetcher do
    @moduledoc """
    Returns the JWKS result set with `set/1` (default `{:error, :no_stub}`), from application
    env so the `WriteApi.Auth.Jwks` process sees it. `notify/1` makes each fetch send
    `:jwks_fetched` to a pid. `set({:raise, message})`, `set({:exit, reason})` and
    `set({:throw, value})` make the fetch raise, exit or throw instead of returning.
    """
    @behaviour WriteApi.Auth.JwksFetcher

    def set(result), do: Application.put_env(:write_api, :stub_jwks_result, result)
    def notify(pid), do: Application.put_env(:write_api, :stub_jwks_notify, pid)

    def reset do
      Application.delete_env(:write_api, :stub_jwks_result)
      Application.delete_env(:write_api, :stub_jwks_notify)
    end

    @impl true
    def fetch do
      if pid = Application.get_env(:write_api, :stub_jwks_notify), do: send(pid, :jwks_fetched)

      case Application.get_env(:write_api, :stub_jwks_result, {:error, :no_stub}) do
        {:raise, message} -> raise message
        {:exit, reason} -> exit(reason)
        {:throw, value} -> throw(value)
        result -> result
      end
    end
  end

  defmodule FakeClock do
    @moduledoc """
    A millisecond clock the test moves by hand, for `WriteApi.Auth.Jwks` (config key
    `:jwks_clock`). `install/1` sets it for the calling test; `advance/1` moves it forward.
    """

    def install(start_ms) do
      Application.put_env(:write_api, :fake_clock_ms, start_ms)
      Application.put_env(:write_api, :jwks_clock, __MODULE__)

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:write_api, :jwks_clock)
        Application.delete_env(:write_api, :fake_clock_ms)
      end)
    end

    def advance(ms),
      do: Application.put_env(:write_api, :fake_clock_ms, now_ms() + ms)

    def now_ms, do: Application.fetch_env!(:write_api, :fake_clock_ms)
  end

  @doc "Swaps an application env value for the duration of the test."
  def swap_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(app, key, old) end)
  end
end
