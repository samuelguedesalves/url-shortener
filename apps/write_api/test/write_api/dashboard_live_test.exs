defmodule WriteApi.DashboardLiveTest do
  use WriteApi.DashboardCase, async: false

  alias WriteApi.Dashboard.Auth
  alias WriteApi.Doubles
  alias WriteApi.Doubles.DownUserStore
  alias WriteApi.Session

  describe "GET /dashboard" do
    test "GET /dashboard renders and links the stylesheet and script" do
      html = build_conn() |> get("/dashboard") |> html_response(200)

      assert html =~ "/assets/app.css"
      assert html =~ "/assets/app.js"
    end

    test "a visit without a cookie mounts signed out" do
      {:ok, view, html} = live(build_conn(), "/dashboard")

      assert html =~ ~s(data-test="signed-out")
      assert has_element?(view, ~s([data-test="signed-out"]))
      refute has_element?(view, ~s([data-test="signed-in"]))
    end

    test "a visit with a valid cookie mounts as that user" do
      user!("alice")

      {:ok, view, html} = live(signed_in_conn("alice"), "/dashboard")

      assert html =~ ~s(data-test="signed-in")
      assert has_element?(view, ~s([data-test="signed-in"]))
      refute has_element?(view, ~s([data-test="signed-out"]))
    end

    test "an expired, tampered or unknown-user cookie mounts signed out" do
      user!("alice")
      ttl = WriteApi.Config.session_ttl()
      expired = signed_in_conn("alice", now: DateTime.add(DateTime.utc_now(), -ttl - 1))

      token = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      tampered = put_req_cookie(build_conn(), "session", token <> "x")

      unknown = signed_in_conn("ghost")

      for conn <- [expired, tampered, unknown] do
        {:ok, view, _html} = live(conn, "/dashboard")

        assert has_element?(view, ~s([data-test="signed-out"]))
        refute has_element?(view, ~s([data-test="signed-in"]))
      end
    end

    test "an unavailable user store mounts signed out with the unavailable message" do
      user!("alice")
      Doubles.swap_env(:shortener_core, :user_store, DownUserStore)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="signed-out"]))
      refute has_element?(view, ~s([data-test="signed-in"]))
      assert has_element?(view, ~s([data-test="auth-unavailable"]), "indisponível")
    end
  end

  describe "the session token in the page" do
    test "the page never carries the raw session cookie" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      conn = put_req_cookie(build_conn(), "session", raw)

      html = conn |> get("/dashboard") |> html_response(200)
      [_, phx_session] = Regex.run(~r/data-phx-session="([^"]+)"/, html)

      {:ok, {_vsn, %{session: session}}} =
        Phoenix.Token.verify(
          WriteApi.Endpoint,
          Phoenix.LiveView.Utils.salt!(WriteApi.Endpoint),
          phx_session,
          max_age: 60
        )

      assert is_binary(session["session_token"])
      refute session["session_token"] == raw
      refute html =~ raw
    end

    test "a live session token that does not decrypt mounts signed out" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value

      for value <- [raw, raw <> "x", "garbage", nil] do
        {:cont, socket} =
          Auth.on_mount(:fetch_user, %{}, %{"session_token" => value}, %Phoenix.LiveView.Socket{})

        assert %{current_user: nil, sealed_session_token: nil, auth_error: nil} = socket.assigns
      end
    end

    test "an encrypted live session token mounts as that user and keeps it sealed" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      conn = put_req_cookie(build_conn(), "session", raw)
      session = Auth.live_session(conn)

      {:cont, socket} = Auth.on_mount(:fetch_user, %{}, session, %Phoenix.LiveView.Socket{})

      assert %{current_user: %{id: "alice"}, sealed_session_token: sealed} = socket.assigns
      assert is_binary(sealed)
      refute inspect(socket.assigns) =~ raw
      assert Auth.unseal(sealed) == raw
    end

    test "the live process state never holds the raw session cookie" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      conn = put_req_cookie(build_conn(), "session", raw)

      {:ok, view, _html} = live(conn, "/dashboard")
      assert has_element?(view, ~s([data-test="signed-in"]))

      # What a crash report prints as "State:" (Phoenix.LiveView.Channel.format_status/2).
      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               raw
    end

    test "a crash of the live view does not log the raw session cookie" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      conn = put_req_cookie(build_conn(), "session", raw)
      {:ok, view, _html} = live(conn, "/dashboard")
      Process.flag(:trap_exit, true)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # No handle_event clause matches: the live process crashes with a FunctionClauseError.
          catch_exit(render_click(view, "no_such_event", %{}))
          refute Process.alive?(view.pid)
        end)

      assert log =~ "no_such_event"
      refute log =~ raw
    end
  end

  describe "the websocket origin check" do
    test "a foreign Origin is refused for the websocket" do
      refute Auth.check_origin?(URI.parse("http://evil.test"))
      assert Auth.check_origin?(URI.parse("http://dashboard.test"))
    end

    test "every Origin is refused while no dashboard origin is configured" do
      Doubles.swap_env(:write_api, :dashboard_origin, nil)

      refute Auth.check_origin?(URI.parse("http://dashboard.test"))
    end
  end
end
