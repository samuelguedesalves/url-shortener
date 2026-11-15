defmodule WriteApi.PlugsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ShortenerCore.{User, UserStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.DownUserStore
  alias WriteApi.Plugs.{FetchUser, RequireUser}
  alias WriteApi.Session

  setup do
    start_supervised!(UserStore.Memory)

    user = %User{
      id: "0b8a2d9e-6d0c-4b5c-8f0e-3d6f1f4f6a11",
      google_id: "109876543210987654321",
      email: "ada@example.com",
      name: "Ada Lovelace",
      picture_url: nil,
      email_verified: true,
      created_at: ~U[2026-11-09 13:00:00.000Z],
      updated_at: ~U[2026-11-09 13:00:00.000Z]
    }

    :ok = UserStore.put(user)
    {:ok, user: user}
  end

  # A request carrying a session cookie for `user_id`.
  defp request_as(user_id) do
    value = (conn(:get, "/") |> Session.issue(user_id)).resp_cookies["session"].value
    put_req_cookie(conn(:get, "/"), "session", value)
  end

  defp fetch_user(conn), do: FetchUser.call(conn, FetchUser.init([]))

  describe "FetchUser" do
    test "no cookie: current_user is nil" do
      conn = fetch_user(conn(:get, "/"))
      assert conn.assigns.current_user == nil
      refute conn.halted
    end

    test "a bad cookie: current_user is nil" do
      conn = :get |> conn("/") |> put_req_cookie("session", "junk") |> fetch_user()
      assert conn.assigns.current_user == nil
      refute conn.halted
    end

    test "a valid cookie for an existing user: current_user is that user", %{user: user} do
      conn = user.id |> request_as() |> fetch_user()
      assert conn.assigns.current_user == user
      refute conn.halted
    end

    test "a cookie for a deleted user: current_user is nil" do
      conn = "11111111-2222-4333-8444-555555555555" |> request_as() |> fetch_user()
      assert conn.assigns.current_user == nil
      refute conn.halted
    end

    test "a down user store halts with 503", %{user: user} do
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      conn = user.id |> request_as() |> fetch_user()

      assert conn.halted
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "unavailable"}
    end

    test "a down user store does not matter without a cookie" do
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      conn = fetch_user(conn(:get, "/"))

      refute conn.halted
      assert conn.assigns.current_user == nil
    end
  end

  describe "RequireUser" do
    test "halts with 401 when current_user is nil" do
      conn =
        :get |> conn("/") |> assign(:current_user, nil) |> RequireUser.call(RequireUser.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthenticated"}
    end

    test "passes a signed-in user through", %{user: user} do
      conn =
        :get |> conn("/") |> assign(:current_user, user) |> RequireUser.call(RequireUser.init([]))

      refute conn.halted
      assert conn.assigns.current_user == user
    end
  end
end
