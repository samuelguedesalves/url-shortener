defmodule WriteApi.Plugs.Cors do
  @moduledoc """
  CORS for the dashboard origin, plus an origin check that doubles as CSRF protection for the
  cookie session.

  The one allowed origin is the `:dashboard_origin` config value (compared exactly, as sent).

    * `OPTIONS` is answered here with 204. The CORS headers are added only for the allowed origin.
    * Any other request from the allowed origin gets `access-control-allow-origin`,
      `access-control-allow-credentials` and `vary: origin`.
    * A state-changing request (anything but GET and HEAD) that carries an `Origin` other than the
      allowed one is refused with 403 `forbidden_origin`. When no origin is configured, any
      `Origin` is "other". This runs before `Plug.Parsers`, so nothing is read or created.
    * A request without an `Origin` header (curl, scripts, server-to-server) passes: browsers
      always send `Origin` on cross-site POSTs, so the check stops the browser attack without
      getting in the way of non-browser clients.

  Origins are never reflected unless they equal the configured one, and the wildcard is never
  used, because responses carry credentials.
  """

  @behaviour Plug

  import Plug.Conn

  @safe_methods ["GET", "HEAD"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    allowed = allowed_origin()

    case get_req_header(conn, "origin") do
      [^allowed] when is_binary(allowed) -> allowed_origin_request(conn, allowed)
      origins -> other_request(conn, origins)
    end
  end

  defp allowed_origin_request(%{method: "OPTIONS"} = conn, allowed) do
    conn
    |> put_cors_headers(allowed)
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-max-age", "600")
    |> send_resp(204, "")
    |> halt()
  end

  defp allowed_origin_request(conn, allowed), do: put_cors_headers(conn, allowed)

  # No Origin header, or one that is not the allowed origin.
  defp other_request(%{method: "OPTIONS"} = conn, _origins),
    do: conn |> send_resp(204, "") |> halt()

  defp other_request(%{method: method} = conn, [_ | _]) when method not in @safe_methods do
    conn
    |> put_status(403)
    |> Phoenix.Controller.json(%{error: "forbidden_origin"})
    |> halt()
  end

  defp other_request(conn, _origins), do: conn

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("vary", "origin")
  end

  defp allowed_origin do
    case Application.get_env(:write_api, :dashboard_origin) do
      origin when is_binary(origin) and origin != "" -> origin
      _ -> nil
    end
  end
end
