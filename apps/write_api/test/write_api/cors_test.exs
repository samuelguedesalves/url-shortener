defmodule WriteApi.CorsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, UrlStore, UserStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.FakeVerifier

  @endpoint WriteApi.Endpoint

  @allowed "http://dashboard.test"
  @foreign "http://evil.test"

  @claims %{
    "sub" => "109876543210987654321",
    "email" => "ada@example.com",
    "email_verified" => true,
    "name" => "Ada Lovelace",
    "picture" => "https://example.com/ada.png"
  }

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    start_supervised!(UserStore.Memory)
    start_supervised!(FakeVerifier)
    FakeVerifier.allow("good-token", @claims)
    :ok
  end

  defp with_origin(conn, nil), do: conn
  defp with_origin(conn, origin), do: put_req_header(conn, "origin", origin)

  defp preflight(origin) do
    build_conn()
    |> with_origin(origin)
    |> put_req_header("access-control-request-method", "POST")
    |> put_req_header("access-control-request-headers", "content-type")
    |> dispatch(@endpoint, :options, "/urls")
  end

  defp post_json(path, body, origin) do
    build_conn()
    |> with_origin(origin)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp cors_headers(conn) do
    for {"access-control-" <> _ = name, _} <- conn.resp_headers, do: name
  end

  describe "preflight" do
    test "from the allowed origin is 204 with the CORS headers" do
      conn = preflight(@allowed)

      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["content-type"]
      assert get_resp_header(conn, "access-control-max-age") == ["600"]
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "from another origin is 204 with no CORS headers" do
      conn = preflight(@foreign)

      assert conn.status == 204
      assert cors_headers(conn) == []
    end

    test "without an Origin header is 204 with no CORS headers" do
      conn = preflight(nil)

      assert conn.status == 204
      assert cors_headers(conn) == []
    end

    test "never answers with a wildcard origin" do
      for origin <- [@allowed, @foreign] do
        refute get_resp_header(preflight(origin), "access-control-allow-origin") == ["*"]
      end
    end
  end

  describe "requests from the allowed origin" do
    test "a POST works and carries the CORS headers" do
      conn = post_json("/urls", %{url: "https://example.com/a"}, @allowed)

      assert conn.status == 201
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "a GET /me carries allow-origin and credentials even when unauthenticated" do
      conn =
        build_conn()
        |> put_req_header("origin", @allowed)
        |> get("/me")

      assert conn.status == 401
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert "origin" in get_resp_header(conn, "vary")
    end

    test "sign-in works and carries the CORS headers" do
      conn = post_json("/auth/google", %{credential: "good-token"}, @allowed)

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    end
  end

  describe "requests from another origin" do
    test "a GET passes through without CORS headers" do
      conn =
        build_conn()
        |> put_req_header("origin", @foreign)
        |> get("/health")

      assert conn.status == 200
      assert cors_headers(conn) == []
    end

    test "POST /urls is 403 forbidden_origin and creates nothing" do
      conn = post_json("/urls", %{url: "https://example.com/a", custom_alias: "mine"}, @foreign)

      assert conn.status == 403
      assert json_response(conn, 403) == %{"error" => "forbidden_origin"}
      assert cors_headers(conn) == []
      assert UrlStore.fetch("mine") == :not_found
    end

    test "POST /auth/google is 403 and never reaches the verifier" do
      conn = post_json("/auth/google", %{credential: "good-token"}, @foreign)

      assert json_response(conn, 403) == %{"error" => "forbidden_origin"}
      assert conn.resp_cookies == %{}
      assert UserStore.get_by_google_id("109876543210987654321") == :not_found
    end

    test "is rejected before the body is parsed" do
      conn =
        build_conn()
        |> put_req_header("origin", @foreign)
        |> put_req_header("content-type", "application/json")
        |> post("/urls", "{not json")

      assert json_response(conn, 403) == %{"error" => "forbidden_origin"}
    end

    test "origins are compared exactly" do
      for origin <- ["http://dashboard.test:8080", "https://dashboard.test", "null"] do
        conn = post_json("/urls", %{url: "https://example.com/a"}, origin)
        assert conn.status == 403, "expected #{origin} to be refused"
      end
    end
  end

  describe "requests with no Origin header" do
    test "POST /urls still creates a link" do
      conn = post_json("/urls", %{url: "https://example.com/a"}, nil)

      assert conn.status == 201
      assert cors_headers(conn) == []
    end
  end

  describe "when dashboard_origin is not configured" do
    setup do
      Doubles.swap_env(:write_api, :dashboard_origin, nil)
      :ok
    end

    test "a preflight gets no CORS headers" do
      conn = preflight(@allowed)

      assert conn.status == 204
      assert cors_headers(conn) == []
    end

    test "a POST with any Origin is 403" do
      conn = post_json("/urls", %{url: "https://example.com/a"}, @allowed)

      assert json_response(conn, 403) == %{"error" => "forbidden_origin"}
    end

    test "a POST with no Origin still works" do
      assert post_json("/urls", %{url: "https://example.com/a"}, nil).status == 201
    end

    test "a GET with an Origin carries no CORS headers" do
      conn = build_conn() |> put_req_header("origin", @allowed) |> get("/health")

      assert conn.status == 200
      assert cors_headers(conn) == []
    end
  end
end
