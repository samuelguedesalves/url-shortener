defmodule WriteApi.UrlListTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, Url, User, UrlStore, UserStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.DownStore
  alias WriteApi.{Session, Shortener}

  @endpoint WriteApi.Endpoint

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    start_supervised!(UserStore.Memory)
    :ok
  end

  defp user!(id) do
    now = ~U[2026-11-01 10:00:00.000Z]

    user = %User{
      id: id,
      google_id: "google-" <> id,
      email: id <> "@example.com",
      name: id,
      picture_url: nil,
      email_verified: true,
      created_at: now,
      updated_at: now
    }

    :ok = UserStore.put(user)
    user
  end

  # A request signed in as `user_id`: the cookie is issued exactly as POST /auth/google does.
  defp signed_in(user_id) do
    cookie = Session.issue(build_conn(), user_id).resp_cookies["session"].value
    put_req_cookie(build_conn(), "session", cookie)
  end

  defp list(user_id, query \\ "") do
    get(signed_in(user_id), "/urls" <> query)
  end

  defp create!(owner_id, params, opts \\ []) do
    {:ok, %{code: code}} = Shortener.create(params, [owner_id: owner_id] ++ opts)
    code
  end

  defp codes(body), do: Enum.map(body["links"], & &1["code"])

  describe "GET /urls" do
    test "without a session is 401 unauthenticated" do
      conn = get(build_conn(), "/urls")
      assert %{"error" => "unauthenticated"} = json_response(conn, 401)
    end

    test "with an invalid session cookie is 401 unauthenticated" do
      conn = build_conn() |> put_req_cookie("session", "garbage") |> get("/urls")
      assert %{"error" => "unauthenticated"} = json_response(conn, 401)
    end

    test "a user with no links gets an empty list and no cursor" do
      user!("alice")

      assert %{"links" => [], "next_cursor" => nil} = json_response(list("alice"), 200)
    end

    test "each user sees only their own links" do
      user!("alice")
      user!("bob")
      a = create!("alice", %{"url" => "https://example.com/a"})
      b = create!("bob", %{"url" => "https://example.com/b"})
      _anonymous = create!(nil, %{"url" => "https://example.com/anon"})

      assert [^a] = codes(json_response(list("alice"), 200))
      assert [^b] = codes(json_response(list("bob"), 200))
    end

    test "returns the link fields" do
      user!("alice")
      now = DateTime.truncate(DateTime.utc_now(), :millisecond)

      code =
        create!("alice", %{"url" => "https://example.com/a", "ttl_seconds" => 3_600}, now: now)

      assert %{"links" => [link], "next_cursor" => nil} = json_response(list("alice"), 200)

      assert link == %{
               "code" => code,
               "short_url" => "http://localhost:4002/" <> code,
               "long_url" => "https://example.com/a",
               "is_custom_alias" => false,
               "created_at" => DateTime.to_iso8601(now),
               "expires_at" => DateTime.to_iso8601(DateTime.add(now, 3_600, :second)),
               "status" => "active"
             }
    end

    test "a generated link and a custom alias carry the right is_custom_alias" do
      user!("alice")
      now = DateTime.truncate(DateTime.utc_now(), :millisecond)
      generated = create!("alice", %{"url" => "https://example.com/g"}, now: now)

      custom =
        create!("alice", %{"url" => "https://example.com/c", "custom_alias" => "my-link"},
          now: DateTime.add(now, 1, :second)
        )

      assert %{"links" => links} = json_response(list("alice"), 200)

      assert Enum.map(links, &{&1["code"], &1["is_custom_alias"]}) == [
               {custom, true},
               {generated, false}
             ]
    end

    test "an expired link is listed with status expired and a null long_url" do
      user!("alice")

      :ok =
        UrlStore.claim(%Url{
          code: "old-link",
          owner_id: "alice",
          is_custom_alias: true,
          created_at: ~U[2026-11-01 10:00:00.000Z],
          expires_at: ~U[2026-11-02 10:00:00.000Z]
        })

      :ok = UrlStore.put_destination("old-link", "https://example.com/old", 0)

      assert %{"links" => [link]} = json_response(list("alice"), 200)
      assert %{"code" => "old-link", "status" => "expired", "long_url" => nil} = link
    end

    test "25 links page as 10, 10 and 5 by following next_cursor, with no gap or duplicate" do
      user!("alice")
      # Links created in the same millisecond tie on created_at and are ordered by code.
      created = for i <- 1..25, do: create!("alice", %{"url" => "https://example.com/#{i}"})

      body1 = json_response(list("alice", "?limit=10"), 200)
      assert length(body1["links"]) == 10
      assert is_binary(body1["next_cursor"])

      body2 = json_response(list("alice", "?limit=10&cursor=" <> body1["next_cursor"]), 200)
      assert length(body2["links"]) == 10
      assert is_binary(body2["next_cursor"])

      body3 = json_response(list("alice", "?limit=10&cursor=" <> body2["next_cursor"]), 200)
      assert length(body3["links"]) == 5
      assert body3["next_cursor"] == nil

      listed = codes(body1) ++ codes(body2) ++ codes(body3)
      assert length(listed) == 25
      assert Enum.sort(listed) == Enum.sort(created)
    end

    test "pages in newest-first order across pages (explicit creation times)" do
      user!("alice")
      base = ~U[2026-11-09 12:00:00.000Z]

      created =
        for i <- 1..5 do
          create!("alice", %{"url" => "https://example.com/#{i}"},
            now: DateTime.add(base, i, :second)
          )
        end

      body1 = json_response(list("alice", "?limit=3"), 200)
      body2 = json_response(list("alice", "?limit=3&cursor=" <> body1["next_cursor"]), 200)

      assert codes(body1) ++ codes(body2) == Enum.reverse(created)
      assert body2["next_cursor"] == nil
    end

    test "the default page size applies without a limit" do
      user!("alice")
      for i <- 1..21, do: create!("alice", %{"url" => "https://example.com/#{i}"})

      body = json_response(list("alice"), 200)
      assert length(body["links"]) == 20
      assert is_binary(body["next_cursor"])
    end

    test "a bad limit is 422 invalid_limit" do
      user!("alice")

      for limit <- ["0", "101", "abc", "1.5"] do
        conn = list("alice", "?limit=" <> limit)
        assert %{"error" => "invalid_limit"} = json_response(conn, 422)
      end
    end

    test "limit 1 and limit 100 are accepted" do
      user!("alice")

      assert 200 = list("alice", "?limit=1").status
      assert 200 = list("alice", "?limit=100").status
    end

    test "a garbage cursor is 422 invalid_cursor" do
      user!("alice")

      conn = list("alice", "?cursor=garbage")
      assert %{"error" => "invalid_cursor"} = json_response(conn, 422)
    end

    test "another user's cursor never shows that user's links" do
      user!("alice")
      user!("bob")
      base = ~U[2026-11-09 12:00:00.000Z]

      # Bob's links are older than Alice's cursor, so a cursor that leaked across owners
      # would still have plenty of rows to return.
      bob_codes =
        for i <- 1..3 do
          create!("bob", %{"url" => "https://example.com/b#{i}"},
            now: DateTime.add(base, i, :second)
          )
        end

      alice_codes =
        for i <- 11..15 do
          create!("alice", %{"url" => "https://example.com/a#{i}"},
            now: DateTime.add(base, i, :second)
          )
        end

      %{"next_cursor" => alice_cursor} = json_response(list("alice", "?limit=2"), 200)
      assert is_binary(alice_cursor)

      body = json_response(list("bob", "?cursor=" <> alice_cursor), 200)

      assert Enum.sort(codes(body)) == Enum.sort(bob_codes)
      assert codes(body) -- alice_codes == codes(body)
    end

    test "a down store is 503 unavailable" do
      user!("alice")
      conn = signed_in("alice")
      Doubles.swap_env(:shortener_core, :url_store, DownStore)

      assert %{"error" => "unavailable"} = json_response(get(conn, "/urls"), 503)
    end

    test "a down user store is 503 unavailable" do
      user!("alice")
      conn = signed_in("alice")
      Doubles.swap_env(:shortener_core, :user_store, Doubles.DownUserStore)

      assert %{"error" => "unavailable"} = json_response(get(conn, "/urls"), 503)
    end
  end
end
