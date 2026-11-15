defmodule WriteApi.UrlControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, User, UrlStore, UserStore}
  alias WriteApi.Doubles

  alias WriteApi.Doubles.{
    DestinationFailsStore,
    DownCache,
    DownStore,
    DownUserStore,
    ScriptedKeySource
  }

  alias WriteApi.Session

  @endpoint WriteApi.Endpoint

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    start_supervised!(UserStore.Memory)
    :ok
  end

  defp user!(id) do
    now = ~U[2026-11-01 10:00:00.000Z]

    :ok =
      UserStore.put(%User{
        id: id,
        google_id: "google-" <> id,
        email: id <> "@example.com",
        name: id,
        picture_url: nil,
        email_verified: true,
        created_at: now,
        updated_at: now
      })
  end

  # A request carrying a session cookie issued as POST /auth/google does.
  defp with_session(user_id, opts \\ []) do
    cookie = Session.issue(build_conn(), user_id, opts).resp_cookies["session"].value
    put_req_cookie(build_conn(), "session", cookie)
  end

  defp post_json_as(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/urls", Jason.encode!(body))
  end

  defp post_json(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/urls", if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  describe "POST /urls ownership" do
    test "POST /urls responds with exactly code, short_url, expires_at, is_custom_alias" do
      body = json_response(post_json(%{"url" => "https://example.com/a"}), 201)

      assert body |> Map.keys() |> Enum.sort() == [
               "code",
               "expires_at",
               "is_custom_alias",
               "short_url"
             ]
    end

    test "the 201 body has exactly code, short_url, expires_at and is_custom_alias" do
      conn = post_json(%{"url" => "https://example.com/a"})
      body = json_response(conn, 201)
      assert Enum.sort(Map.keys(body)) == ["code", "expires_at", "is_custom_alias", "short_url"]
      assert body["is_custom_alias"] == false

      conn = post_json(%{"url" => "https://example.com/a", "custom_alias" => "named-one"})
      assert %{"code" => "named-one", "is_custom_alias" => true} = json_response(conn, 201)
    end

    test "a signed-in create is owned by the user and listed with is_custom_alias" do
      user!("alice")
      req = fn -> with_session("alice") end

      %{"code" => generated} =
        json_response(post_json_as(req.(), %{"url" => "https://example.com/g"}), 201)

      conn =
        post_json_as(req.(), %{"url" => "https://example.com/c", "custom_alias" => "alice-link"})

      assert %{"code" => "alice-link", "is_custom_alias" => true} = json_response(conn, 201)

      assert {:ok, %{owner_id: "alice"}} = UrlStore.fetch(generated)
      assert {:ok, %{owner_id: "alice"}} = UrlStore.fetch("alice-link")

      %{"links" => links} = json_response(get(req.(), "/urls"), 200)
      flags = Map.new(links, &{&1["code"], &1["is_custom_alias"]})
      assert flags == %{generated => false, "alice-link" => true}
    end

    test "an anonymous create has no owner and is listed for nobody" do
      user!("alice")
      %{"code" => code} = json_response(post_json(%{"url" => "https://example.com/a"}), 201)

      assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
      assert %{"links" => []} = json_response(get(with_session("alice"), "/urls"), 200)
    end

    test "an owner_id in an anonymous body is ignored" do
      user!("alice")
      body = %{"url" => "https://example.com/a", "owner_id" => "alice"}
      %{"code" => code} = json_response(post_json(body), 201)

      assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
      assert %{"links" => []} = json_response(get(with_session("alice"), "/urls"), 200)
    end

    test "an owner_id in a signed-in body is ignored in favour of the session user" do
      user!("alice")
      user!("bob")
      body = %{"url" => "https://example.com/a", "owner_id" => "bob"}
      %{"code" => code} = json_response(post_json_as(with_session("alice"), body), 201)

      assert {:ok, %{owner_id: "alice"}} = UrlStore.fetch(code)
      assert %{"links" => []} = json_response(get(with_session("bob"), "/urls"), 200)
    end

    test "a tampered cookie still creates an anonymous link with 201" do
      user!("alice")
      cookie = Session.issue(build_conn(), "alice").resp_cookies["session"].value

      conn =
        build_conn()
        |> put_req_cookie("session", cookie <> "x")
        |> post_json_as(%{"url" => "https://example.com/a"})

      %{"code" => code} = json_response(conn, 201)
      assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
    end

    test "an expired cookie still creates an anonymous link with 201" do
      user!("alice")
      eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

      conn =
        "alice"
        |> with_session(now: eight_days_ago)
        |> post_json_as(%{"url" => "https://example.com/a"})

      %{"code" => code} = json_response(conn, 201)
      assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
    end

    test "a cookie for a deleted user creates an anonymous link with 201" do
      conn = "ghost" |> with_session() |> post_json_as(%{"url" => "https://example.com/a"})
      %{"code" => code} = json_response(conn, 201)
      assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
    end

    test "a user-store outage while reading a present cookie is 503" do
      user!("alice")
      conn = with_session("alice")
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      conn = post_json_as(conn, %{"url" => "https://example.com/a"})
      assert %{"error" => "unavailable"} = json_response(conn, 503)
    end

    test "a taken alias is 409 while signed in" do
      user!("alice")
      body = %{"url" => "https://example.com/a", "custom_alias" => "taken-2"}
      assert json_response(post_json(body), 201)

      conn = post_json_as(with_session("alice"), body)
      assert %{"error" => "alias_taken"} = json_response(conn, 409)
    end

    for alias_name <- ~w(auth me login logout links Me LOGIN) do
      test "the reserved alias #{alias_name} is 422 invalid_alias, anonymous and signed in" do
        body = %{"url" => "https://example.com/a", "custom_alias" => unquote(alias_name)}
        assert %{"error" => "invalid_alias"} = json_response(post_json(body), 422)

        user!("alice")
        conn = post_json_as(with_session("alice"), body)
        assert %{"error" => "invalid_alias"} = json_response(conn, 422)
      end
    end
  end

  describe "POST /urls with a generated code" do
    test "returns 201 with a 7-character code, the short URL and the expiry" do
      conn = post_json(%{"url" => "https://example.com/some/path?q=1"})

      assert %{"code" => code, "short_url" => short_url, "expires_at" => expires_at} =
               json_response(conn, 201)

      assert code =~ ~r/\A[0-9A-Za-z]{7}\z/
      assert short_url == "http://localhost:4002/" <> code
      assert {:ok, _, 0} = DateTime.from_iso8601(expires_at)
    end

    test "stores the destination so it can be fetched" do
      %{"code" => code} = json_response(post_json(%{"url" => "https://example.com/a"}), 201)

      assert {:ok, %{long_url: "https://example.com/a", is_custom_alias: false}} =
               UrlStore.fetch(code)
    end

    test "does not deduplicate: the same URL gets a new code each time" do
      body = %{"url" => "https://example.com/same"}
      %{"code" => a} = json_response(post_json(body), 201)
      %{"code" => b} = json_response(post_json(body), 201)
      assert a != b
    end

    test "honours ttl_seconds for the expiry" do
      before = DateTime.utc_now()
      conn = post_json(%{"url" => "https://example.com", "ttl_seconds" => 120})
      %{"expires_at" => expires_at} = json_response(conn, 201)
      {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)
      assert DateTime.diff(expires_at, before) in 119..122
    end
  end

  describe "POST /urls with a custom alias" do
    test "uses the alias as the code" do
      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "my-link_1"})

      assert %{"code" => "my-link_1", "short_url" => "http://localhost:4002/my-link_1"} =
               json_response(conn, 201)

      assert {:ok, %{is_custom_alias: true}} = UrlStore.fetch("my-link_1")
    end

    test "a taken alias returns 409 and keeps the first destination" do
      body = %{"url" => "https://example.com/first", "custom_alias" => "taken"}
      assert json_response(post_json(body), 201)

      conn = post_json(%{body | "url" => "https://example.com/second"})
      assert %{"error" => "alias_taken"} = json_response(conn, 409)
      assert {:ok, %{long_url: "https://example.com/first"}} = UrlStore.fetch("taken")
    end

    test "clears a negative cache entry for the alias" do
      :ok = Cache.put("later", :not_found, 30)

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "later"}),
               201
             )

      assert Cache.get("later") == :miss
    end

    test "still succeeds when the cache is down" do
      Doubles.swap_env(:shortener_core, :cache, DownCache)
      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "nocache"})
      assert json_response(conn, 201)
    end
  end

  describe "a generated key that clashes with an existing alias (ADR 0001)" do
    setup do
      Doubles.swap_env(:shortener_core, :key_source, ScriptedKeySource)
      :ok
    end

    test "is discarded and the next key is used" do
      start_supervised!({ScriptedKeySource, ["clash01", "fresh01"]})

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "clash01"}),
               201
             )

      conn = post_json(%{"url" => "https://example.com/other"})
      assert %{"code" => "fresh01"} = json_response(conn, 201)
    end

    test "succeeds on the third attempt after two clashes" do
      start_supervised!({ScriptedKeySource, ["aaa0001", "aaa0002", "fresh02"]})

      for alias_name <- ["aaa0001", "aaa0002"] do
        assert json_response(
                 post_json(%{"url" => "https://example.com", "custom_alias" => alias_name}),
                 201
               )
      end

      conn = post_json(%{"url" => "https://example.com/other"})
      assert %{"code" => "fresh02"} = json_response(conn, 201)
    end

    test "returns 503 after 3 clashes in a row" do
      start_supervised!({ScriptedKeySource, ["aaa0001", "aaa0002", "aaa0003", "fresh01"]})

      for alias_name <- ["aaa0001", "aaa0002", "aaa0003"] do
        assert json_response(
                 post_json(%{"url" => "https://example.com", "custom_alias" => alias_name}),
                 201
               )
      end

      conn = post_json(%{"url" => "https://example.com/other"})
      assert %{"error" => "unavailable"} = json_response(conn, 503)
    end

    test "returns 503 when the key source has nothing left" do
      start_supervised!({ScriptedKeySource, []})
      assert json_response(post_json(%{"url" => "https://example.com"}), 503)
    end

    test "custom aliases still work when the key source is down" do
      start_supervised!({ScriptedKeySource, []})

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "stillworks"}),
               201
             )
    end
  end

  describe "storage failures" do
    test "returns 503 when Cassandra is down" do
      Doubles.swap_env(:shortener_core, :url_store, DownStore)

      assert %{"error" => "unavailable"} =
               json_response(post_json(%{"url" => "https://example.com"}), 503)
    end

    test "a failure after the claim returns 503 and burns the code (ADR 0004)" do
      Doubles.swap_env(:shortener_core, :url_store, DestinationFailsStore)

      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "burned"})
      assert json_response(conn, 503)

      assert {:ok, %{long_url: nil}} = UrlStore.Memory.fetch("burned")

      assert UrlStore.Memory.claim(%ShortenerCore.Url{
               code: "burned",
               owner_id: nil,
               is_custom_alias: true,
               created_at: DateTime.utc_now(),
               expires_at: DateTime.utc_now()
             }) == {:error, :taken}
    end
  end

  describe "validation" do
    for {name, body} <- [
          {"a missing url", %{}},
          {"a non-string url", %{"url" => 123}},
          {"a null url", %{"url" => nil}},
          {"an unsupported scheme", %{"url" => "ftp://example.com/file"}},
          {"javascript: urls", %{"url" => "javascript:alert(1)"}},
          {"a url with no host", %{"url" => "https:///path"}},
          {"a url with a lone carriage return", %{"url" => "https://example.com/a\rb"}},
          {"a url with a lone line feed", %{"url" => "https://example.com/a\nb"}},
          {"a url with a CRLF header injection and no space",
           %{"url" => "https://example.com/\r\nSet-Cookie:a=b"}},
          {"a url with a tab", %{"url" => "https://example.com/a\tb"}},
          {"a url with a NUL byte", %{"url" => "https://example.com/a\0b"}},
          {"a url with a DEL character", %{"url" => "https://example.com/a\x7Fb"}},
          {"a url with a space", %{"url" => "https://example.com/a b"}},
          {"a url over 2048 bytes",
           %{"url" => "https://example.com/" <> String.duplicate("a", 2_100)}}
        ] do
      test "rejects #{name} with 422 invalid_url" do
        conn = post_json(unquote(Macro.escape(body)))
        assert %{"error" => "invalid_url"} = json_response(conn, 422)
      end
    end

    for {name, alias_name} <- [
          {"an alias that is too short", "ab"},
          {"an alias that is too long", String.duplicate("a", 33)},
          {"an alias with a slash", "a/b"},
          {"an alias with a space", "a b"},
          {"a reserved alias", "health"},
          {"a reserved alias in another case", "URLS"},
          {"a reserved alias, lowercase", "stats"},
          {"a reserved future route", "metrics"},
          {"a reserved future route in mixed case", "Dashboard"},
          {"a non-string alias", 42}
        ] do
      test "rejects #{name} with 422 invalid_alias" do
        body = %{
          "url" => "https://example.com",
          "custom_alias" => unquote(Macro.escape(alias_name))
        }

        assert %{"error" => "invalid_alias"} = json_response(post_json(body), 422)
      end
    end

    for {name, ttl} <- [
          {"a zero ttl", 0},
          {"a negative ttl", -5},
          {"a float ttl", 1.5},
          {"a string ttl", "60"},
          {"a ttl above the maximum", 315_360_001}
        ] do
      test "rejects #{name} with 422 invalid_ttl" do
        body = %{"url" => "https://example.com", "ttl_seconds" => unquote(ttl)}
        assert %{"error" => "invalid_ttl"} = json_response(post_json(body), 422)
      end
    end

    test "does not read the url from the query string" do
      conn = post(build_conn(), "/urls?url=https://example.com")
      assert %{"error" => "invalid_url"} = json_response(conn, 422)
    end

    test "rejects a JSON array body" do
      assert %{"error" => "invalid_url"} = json_response(post_json("[1,2,3]"), 422)
    end

    test "malformed JSON returns 400 with a JSON body" do
      {400, _headers, body} =
        assert_error_sent 400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/urls", "{not json")
        end

      assert Jason.decode!(body) == %{"error" => "Bad Request"}
    end

    test "a non-JSON content type returns 415 with a JSON body" do
      {415, _headers, body} =
        assert_error_sent 415, fn ->
          build_conn() |> put_req_header("content-type", "text/plain") |> post("/urls", "hello")
        end

      assert Jason.decode!(body) == %{"error" => "Unsupported Media Type"}
    end
  end

  test "GET /health returns ok" do
    assert %{"status" => "ok"} = build_conn() |> get("/health") |> json_response(200)
  end
end
