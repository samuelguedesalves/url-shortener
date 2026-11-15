defmodule WriteApi.SessionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias WriteApi.Doubles
  alias WriteApi.Session

  @user_id "0b8a2d9e-6d0c-4b5c-8f0e-3d6f1f4f6a11"
  @now ~U[2026-11-09 13:00:00Z]

  # Sends the response and returns the raw Set-Cookie header the browser would receive.
  defp set_cookie(conn) do
    conn |> send_resp(200, "") |> get_resp_header("set-cookie") |> List.first()
  end

  defp issued_value(opts \\ []) do
    conn = :get |> conn("/") |> Session.issue(@user_id, opts)
    conn.resp_cookies["session"].value
  end

  defp with_cookie(value), do: :get |> conn("/") |> put_req_cookie("session", value)

  describe "issue/3 and user_id/2" do
    test "round-trips the user id" do
      conn = with_cookie(issued_value())
      assert Session.user_id(conn) == {:ok, @user_id}
    end

    test "no cookie is :none" do
      assert Session.user_id(conn(:get, "/")) == :none
    end

    test "a tampered cookie is :none" do
      value = issued_value()
      pos = div(String.length(value), 2)
      {head, <<char, tail::binary>>} = String.split_at(value, pos)
      flipped = head <> <<if(char == ?A, do: ?B, else: ?A)>> <> tail

      refute flipped == value
      assert Session.user_id(with_cookie(flipped)) == :none
    end

    test "garbage is :none" do
      assert Session.user_id(with_cookie("not-a-token")) == :none
      assert Session.user_id(with_cookie("")) == :none
    end

    test "a cookie signed with another secret is :none" do
      value = issued_value()
      Doubles.swap_env(:write_api, :session_secret, String.duplicate("z", 64))
      assert Session.user_id(with_cookie(value)) == :none
    end

    test "a cookie older than session_ttl is :none" do
      Doubles.swap_env(:write_api, :session_ttl, 100)
      value = issued_value(now: @now)

      assert Session.user_id(with_cookie(value), DateTime.add(@now, 99, :second)) ==
               {:ok, @user_id}

      assert Session.user_id(with_cookie(value), DateTime.add(@now, 100, :second)) == :none
      assert Session.user_id(with_cookie(value), DateTime.add(@now, 8 * 86_400, :second)) == :none
    end

    test "a cookie issued in the future is :none" do
      value = issued_value(now: DateTime.add(@now, 3600, :second))
      assert Session.user_id(with_cookie(value), @now) == :none
    end
  end

  describe "token/1 and verify_token/2" do
    test "token/1 is :none without a cookie" do
      assert Session.token(conn(:get, "/")) == :none
    end

    test "verify_token/2 accepts a token the cookie carries and rejects expired and tampered ones" do
      Doubles.swap_env(:write_api, :session_ttl, 100)
      value = issued_value(now: @now)

      assert {:ok, ^value} = Session.token(with_cookie(value))
      assert Session.verify_token(value, DateTime.add(@now, 99, :second)) == {:ok, @user_id}
      assert Session.verify_token(value, DateTime.add(@now, 100, :second)) == :none
      assert Session.verify_token(value <> "x", @now) == :none
      assert Session.verify_token("not-a-token", @now) == :none
    end
  end

  describe "cookie attributes" do
    test "is HttpOnly, SameSite=Lax, Path=/ and lives for session_ttl" do
      header = :get |> conn("/") |> Session.issue(@user_id) |> set_cookie()

      assert header =~ ~r/^session=/
      assert header =~ "HttpOnly"
      assert header =~ "SameSite=Lax"
      assert header =~ "path=/"
      assert header =~ "max-age=604800"
    end

    test "max-age follows session_ttl" do
      Doubles.swap_env(:write_api, :session_ttl, 60)
      header = :get |> conn("/") |> Session.issue(@user_id) |> set_cookie()
      assert header =~ "max-age=60"
    end

    test "Secure follows cookie_secure" do
      refute :get |> conn("/") |> Session.issue(@user_id) |> set_cookie() =~ "secure"

      Doubles.swap_env(:write_api, :cookie_secure, true)
      assert :get |> conn("/") |> Session.issue(@user_id) |> set_cookie() =~ "secure"
    end
  end

  describe "clear/1" do
    test "expires the cookie" do
      header = :get |> conn("/") |> Session.clear() |> set_cookie()

      assert header =~ ~r/^session=;/
      assert header =~ "max-age=0"
      assert header =~ "path=/"
    end
  end
end
