defmodule WriteApi.AuthController do
  use Phoenix.Controller, formats: [:json]

  alias ShortenerCore.Users
  alias WriteApi.Auth.Verifier
  alias WriteApi.{Session, UserView}

  # Only the request body is read; query-string parameters are ignored. The credential is
  # kept out of Phoenix's parameter log by `config :phoenix, :filter_parameters` (config.exs);
  # this module does not log it either.
  def google(conn, _params) do
    with {:ok, credential} <- credential(conn.body_params),
         {:ok, claims} <- Verifier.verify(credential),
         {:ok, user} <- Users.register_or_update(claims) do
      conn
      |> Session.issue(user.id)
      |> json(UserView.to_map(user))
    else
      {:error, :invalid_request} ->
        error(conn, :unprocessable_entity, "invalid_request")

      {:error, reason} when reason in [:invalid_token, :invalid_claims] ->
        error(conn, :unauthorized, "invalid_token")

      {:error, :unavailable} ->
        error(conn, :service_unavailable, "unavailable")
    end
  end

  def logout(conn, _params) do
    conn |> Session.clear() |> send_resp(:no_content, "")
  end

  defp credential(%{"credential" => credential}) when is_binary(credential) do
    if String.trim(credential) == "", do: {:error, :invalid_request}, else: {:ok, credential}
  end

  defp credential(_body), do: {:error, :invalid_request}

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
