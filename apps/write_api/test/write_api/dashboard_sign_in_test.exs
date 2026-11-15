defmodule WriteApi.DashboardSignInTest do
  use WriteApi.DashboardCase, async: false

  alias WriteApi.Doubles

  @client_id "the-id.apps.googleusercontent.com"

  describe "signed out" do
    test "signed out with a client id renders the Google button hook configured with it" do
      Doubles.swap_env(:write_api, :google_client_id, @client_id)

      {:ok, view, html} = live(build_conn(), "/dashboard")

      assert html =~ ~s(phx-hook="GoogleSignIn")
      assert html =~ ~s(data-client-id="#{@client_id}")
      assert has_element?(view, ~s([phx-hook="GoogleSignIn"][data-client-id="#{@client_id}"]))
      refute has_element?(view, ~s([phx-hook="SignOut"]))
      refute has_element?(view, ~s([data-test="link"]))
    end

    test "signed out without a client id shows the not-configured message and no button" do
      Doubles.swap_env(:write_api, :google_client_id, nil)

      {:ok, view, html} = live(build_conn(), "/dashboard")

      assert html =~ "GOOGLE_CLIENT_ID"
      assert has_element?(view, ~s([data-test="sign-in-not-configured"]))
      refute html =~ ~s(phx-hook="GoogleSignIn")
    end

    test "a client id with quotes and angle brackets is escaped in the attribute" do
      Doubles.swap_env(:write_api, :google_client_id, ~S|a"><script>alert(1)</script>|)

      {:ok, _view, html} = live(build_conn(), "/dashboard")

      refute html =~ "<script>alert(1)"
      assert html =~ ~S|data-client-id="a&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;"|
    end

    test "sign_in_failed shows a message per code" do
      Doubles.swap_env(:write_api, :google_client_id, @client_id)
      {:ok, view, _html} = live(build_conn(), "/dashboard")

      messages =
        for code <- ["invalid_token", "unavailable", "forbidden_origin", "script_blocked", "nope"] do
          render_hook(view, "sign_in_failed", %{"code" => code})
          assert has_element?(view, ~s([data-test="sign-in-error"]))
          view |> element(~s([data-test="sign-in-error"])) |> render()
        end

      assert length(Enum.uniq(messages)) == 5
      assert Enum.at(messages, 2) =~ "DASHBOARD_ORIGIN"
      assert Enum.at(messages, 3) =~ "bloque"
      # The button stays rendered so the user can retry.
      assert has_element?(view, ~s([phx-hook="GoogleSignIn"]))
    end

    test "an unavailable user store shows the unavailable message, not a plain login card" do
      user!("alice")
      Doubles.swap_env(:shortener_core, :user_store, Doubles.DownUserStore)
      Doubles.swap_env(:write_api, :google_client_id, @client_id)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="signed-out"]))
      assert has_element?(view, ~s([data-test="auth-unavailable"]))
    end

    test "a plain signed-out visit does not show the unavailable message" do
      Doubles.swap_env(:write_api, :google_client_id, @client_id)

      {:ok, view, _html} = live(build_conn(), "/dashboard")

      refute has_element?(view, ~s([data-test="auth-unavailable"]))
      refute has_element?(view, ~s([data-test="sign-in-error"]))
    end
  end

  describe "signed in" do
    test "signed in renders the header with the user's name and a sign-out control" do
      user = user!("alice", %{name: "Alice Souza"})

      {:ok, view, html} = live(signed_in_conn(user.id), "/dashboard")

      assert has_element?(view, ~s([data-test="signed-in"] header))
      assert has_element?(view, ~s(header [data-test="user-name"]), "Alice Souza")
      assert has_element?(view, ~s(header button[phx-hook="SignOut"]))
      assert has_element?(view, ~s([data-test="user-avatar"]), "AS")
      refute html =~ ~s(phx-hook="GoogleSignIn")
    end

    test "the header shows the picture when there is one" do
      user!("alice", %{name: "Alice", picture_url: "https://pics.test/a.png"})

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s(img[data-test="user-avatar"][src="https://pics.test/a.png"]))
    end

    test "a blank name falls back to a placeholder" do
      user!("alice", %{name: "  "})

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="user-avatar"]), "?")
    end

    test "the page never carries the raw session cookie" do
      user!("alice")
      conn = signed_in_conn("alice")
      raw = Plug.Conn.fetch_cookies(conn).req_cookies["session"]

      {:ok, _view, html} = live(conn, "/dashboard")

      assert is_binary(raw)
      refute html =~ raw
    end
  end
end
