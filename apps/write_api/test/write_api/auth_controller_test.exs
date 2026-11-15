defmodule WriteApi.AuthControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.UserStore
  alias WriteApi.Doubles
  alias WriteApi.Doubles.{DownUserStore, FakeVerifier, UnavailableVerifier}

  @endpoint WriteApi.Endpoint

  @claims %{
    "sub" => "109876543210987654321",
    "email" => "ada@example.com",
    "email_verified" => true,
    "name" => "Ada Lovelace",
    "picture" => "https://example.com/ada.png"
  }

  setup do
    # The verifier registry is a globally named Agent: start it fresh for every test.
    start_supervised!(FakeVerifier)
    start_supervised!(UserStore.Memory)
    FakeVerifier.allow("good-token", @claims)
    :ok
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  defp login(credential \\ "good-token"), do: post_json("/auth/google", %{credential: credential})

  defp session_cookie(conn), do: conn.resp_cookies["session"]

  defp get_me(cookie_value) do
    build_conn()
    |> put_req_cookie("session", cookie_value)
    |> get("/me")
  end

  describe "POST /auth/google" do
    test "signs in: 200, the user body, a session cookie, and the user is stored" do
      conn = login()

      assert %{"id" => id, "email" => "ada@example.com", "name" => "Ada Lovelace"} =
               body = json_response(conn, 200)

      assert body["picture_url"] == "https://example.com/ada.png"
      assert Map.keys(body) |> Enum.sort() == ["email", "id", "name", "picture_url"]

      assert %{value: value, http_only: true} = session_cookie(conn)
      assert is_binary(value) and value != ""
      assert {:ok, %{id: ^id, google_id: "109876543210987654321"}} = UserStore.get(id)
    end

    test "the same credential twice gives the same user id" do
      %{"id" => first} = json_response(login(), 200)
      %{"id" => second} = json_response(login(), 200)
      assert first == second
    end

    test "an unknown credential is 401 invalid_token and stores no user" do
      conn = login("bad")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      assert session_cookie(conn) == nil
      assert UserStore.get_by_google_id("109876543210987654321") == :not_found
    end

    test "claims that cannot register a user are 401 invalid_token" do
      FakeVerifier.allow("no-sub", Map.delete(@claims, "sub"))

      conn = login("no-sub")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      assert session_cookie(conn) == nil
    end

    test "a missing credential is 422 invalid_request" do
      assert %{"error" => "invalid_request"} = json_response(post_json("/auth/google", %{}), 422)
    end

    test "a blank credential is 422 invalid_request" do
      assert %{"error" => "invalid_request"} = json_response(login(""), 422)
      assert %{"error" => "invalid_request"} = json_response(login("   "), 422)
    end

    test "a non-string credential is 422 invalid_request" do
      for credential <- [123, nil, true, ["good-token"], %{"a" => "b"}] do
        assert %{"error" => "invalid_request"} = json_response(login(credential), 422)
      end
    end

    test "the credential is read from the body only, not the query string" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/auth/google?credential=good-token", "{}")

      assert %{"error" => "invalid_request"} = json_response(conn, 422)
    end

    test "an unavailable verifier is 503" do
      Doubles.swap_env(:write_api, :verifier, UnavailableVerifier)

      conn = login()

      assert %{"error" => "unavailable"} = json_response(conn, 503)
      assert session_cookie(conn) == nil
    end

    test "a down user store is 503" do
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      conn = login()

      assert %{"error" => "unavailable"} = json_response(conn, 503)
      assert session_cookie(conn) == nil
    end
  end

  describe "logging" do
    # Phoenix logs request parameters at :debug, which the test config silences; raise the
    # level for this test so the parameter line is actually produced.
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "the credential never reaches the log, the parameter shows as [FILTERED]" do
      secret = "eyJ.distinctive-credential-9f3a1c.sig"
      FakeVerifier.allow(secret, @claims)

      log = capture_log(fn -> assert json_response(login(secret), 200) end)

      assert log =~ "Parameters:"
      assert log =~ ~s("credential" => "[FILTERED]")
      refute log =~ "distinctive-credential-9f3a1c"
    end
  end

  describe "GET /me" do
    test "with the cookie from login: 200 and the same user body" do
      conn = login()
      body = json_response(conn, 200)

      me = get_me(session_cookie(conn).value)

      assert json_response(me, 200) == body
    end

    test "without a cookie: 401 unauthenticated" do
      assert %{"error" => "unauthenticated"} = json_response(get(build_conn(), "/me"), 401)
    end

    test "with a tampered cookie: 401 unauthenticated" do
      value = session_cookie(login()).value

      assert %{"error" => "unauthenticated"} =
               json_response(get_me(value <> "x"), 401)

      assert %{"error" => "unauthenticated"} = json_response(get_me("junk"), 401)
    end

    test "for a user that no longer exists: 401 unauthenticated" do
      value = session_cookie(login()).value
      stop_supervised!(UserStore.Memory)
      start_supervised!(UserStore.Memory)

      assert %{"error" => "unauthenticated"} = json_response(get_me(value), 401)
    end

    test "with a down user store: 503" do
      value = session_cookie(login()).value
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      assert %{"error" => "unavailable"} = json_response(get_me(value), 503)
    end
  end

  describe "POST /auth/logout" do
    test "clears the cookie with 204, and /me is 401 afterwards" do
      value = session_cookie(login()).value

      conn =
        build_conn()
        |> put_req_cookie("session", value)
        |> post("/auth/logout")

      assert response(conn, 204) == ""
      assert %{max_age: 0} = session_cookie(conn)

      # A browser drops the expired cookie, so the follow-up request carries none.
      assert %{"error" => "unauthenticated"} = json_response(get(build_conn(), "/me"), 401)
    end

    test "without a session: 204 and the cookie is cleared" do
      conn = post(build_conn(), "/auth/logout")

      assert response(conn, 204) == ""
      assert %{max_age: 0} = session_cookie(conn)
    end
  end
end
