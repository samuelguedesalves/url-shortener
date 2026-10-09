defmodule RedirectApi.RedirectControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, Url, UrlStore}

  @endpoint RedirectApi.Endpoint

  defmodule DownStore do
    @behaviour ShortenerCore.UrlStore
    @impl true
    def claim(_), do: {:error, :unavailable}
    @impl true
    def put_destination(_, _, _), do: {:error, :unavailable}
    @impl true
    def fetch(_), do: {:error, :unavailable}
  end

  defmodule DownCache do
    @behaviour ShortenerCore.Cache
    @impl true
    def get(_), do: {:error, :unavailable}
    @impl true
    def put(_, _, _), do: {:error, :unavailable}
    @impl true
    def delete(_), do: {:error, :unavailable}
  end

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    :ok
  end

  defp swap_env(key, value) do
    old = Application.fetch_env!(:shortener_core, key)
    Application.put_env(:shortener_core, key, value)
    on_exit(fn -> Application.put_env(:shortener_core, key, old) end)
  end

  defp create_link(code, long_url, ttl \\ 3_600) do
    now = DateTime.utc_now()

    :ok =
      UrlStore.claim(%Url{
        code: code,
        owner_id: nil,
        is_custom_alias: false,
        created_at: now,
        expires_at: DateTime.add(now, ttl, :second)
      })

    :ok = UrlStore.put_destination(code, long_url, ttl)
  end

  defp no_store?(conn), do: get_resp_header(conn, "cache-control") == ["no-store"]

  describe "GET /:code for a live link" do
    test "returns 302 with the Location and no-store" do
      create_link("abc1234", "https://example.com/target?x=1")

      conn = get(build_conn(), "/abc1234")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://example.com/target?x=1"]
      assert no_store?(conn)
    end

    test "fills the cache, and a cached link redirects even if the store has lost it" do
      create_link("abc1234", "https://example.com/target")
      assert get(build_conn(), "/abc1234").status == 302
      assert Cache.get("abc1234") == {:ok, {:url, "https://example.com/target"}}

      swap_env(:url_store, DownStore)
      assert get(build_conn(), "/abc1234").status == 302
    end

    test "caps the cache TTL at the link's remaining TTL" do
      create_link("short01", "https://example.com", 10)
      get(build_conn(), "/short01")
      assert Cache.Memory.ttl("short01") in 9..10
    end

    test "caps the cache TTL at the configured maximum" do
      create_link("long001", "https://example.com", 315_360_000)
      get(build_conn(), "/long001")
      assert Cache.Memory.ttl("long001") == Application.fetch_env!(:shortener_core, :cache_ttl)
    end

    test "answers HEAD like GET without a body" do
      create_link("abc1234", "https://example.com")
      conn = head(build_conn(), "/abc1234")
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://example.com"]
    end

    test "serves from the store when Redis is down" do
      create_link("abc1234", "https://example.com")
      swap_env(:cache, DownCache)
      assert get(build_conn(), "/abc1234").status == 302
    end
  end

  describe "GET /:code for an unknown code" do
    test "returns 404 with no-store and caches the miss" do
      conn = get(build_conn(), "/nothere")

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert no_store?(conn)
      assert Cache.get("nothere") == {:ok, :not_found}

      assert Cache.Memory.ttl("nothere") ==
               Application.fetch_env!(:shortener_core, :negative_cache_ttl)
    end

    for code <- ["a.b", "bad%20code", String.duplicate("a", 33), "%E2%82%AC"] do
      test "returns 404 without touching the stores for #{inspect(code)}" do
        swap_env(:url_store, DownStore)
        conn = get(build_conn(), "/" <> unquote(code))
        assert json_response(conn, 404)
        assert no_store?(conn)
      end
    end
  end

  describe "GET /:code for an expired link (ADR 0004)" do
    test "returns 410 with no-store and caches it as gone" do
      create_link("old0001", "https://example.com", 1)
      Process.sleep(1_200)

      conn = get(build_conn(), "/old0001")

      assert json_response(conn, 410) == %{"error" => "gone"}
      assert no_store?(conn)
      assert Cache.get("old0001") == {:ok, :gone}
    end

    test "a claimed code with no destination (crash between the write steps) returns 410" do
      now = DateTime.utc_now()

      :ok =
        UrlStore.claim(%Url{
          code: "burned1",
          owner_id: nil,
          is_custom_alias: false,
          created_at: now,
          expires_at: DateTime.add(now, 3_600)
        })

      assert json_response(get(build_conn(), "/burned1"), 410)
    end
  end

  describe "when Cassandra is down (ADR 0003)" do
    test "a cache miss returns 503 with no-store and caches nothing" do
      swap_env(:url_store, DownStore)

      conn = get(build_conn(), "/abc1234")

      assert json_response(conn, 503) == %{"error" => "unavailable"}
      assert no_store?(conn)
      assert Cache.get("abc1234") == :miss
    end

    test "a cache hit still redirects" do
      :ok = Cache.put("hit0001", {:url, "https://example.com"}, 60)
      swap_env(:url_store, DownStore)
      assert get(build_conn(), "/hit0001").status == 302
    end
  end

  test "GET /health returns ok and is not treated as a code" do
    assert %{"status" => "ok"} = build_conn() |> get("/health") |> json_response(200)
  end
end
