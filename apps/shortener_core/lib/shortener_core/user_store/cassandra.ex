defmodule ShortenerCore.UserStore.Cassandra do
  @moduledoc """
  `UserStore` on Cassandra.

  `claim_google_id/2` is an `INSERT ... IF NOT EXISTS` on `users_by_google_id`, the same
  pattern as `UrlStore.claim/1` (ADR 0004): a lightweight transaction that makes concurrent
  first logins agree on one user id. When it is not applied Cassandra returns the existing
  row, which holds the winner. ADR 0003: every statement runs at QUORUM (the connection
  default); the conditional claim adds serial consistency SERIAL.

  A timed-out claim may or may not have applied. That is safe: the next login claims the same
  `sub` again, gets the id that won, and finishes writing the `users` row.
  """

  @behaviour ShortenerCore.UserStore

  require Logger

  alias ShortenerCore.{Cassandra, User}

  @claim "INSERT INTO users_by_google_id (google_id, user_id) VALUES (?, ?) IF NOT EXISTS"

  @put """
  INSERT INTO users (id, google_id, email, name, picture_url, email_verified, created_at, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  """

  @get """
  SELECT id, google_id, email, name, picture_url, email_verified, created_at, updated_at
  FROM users WHERE id = ?
  """

  @user_id_by_google_id "SELECT user_id FROM users_by_google_id WHERE google_id = ?"

  @impl true
  def get(id) do
    case execute(@get, [id], []) do
      {:ok, page} -> one_user(page)
      {:error, error} -> unavailable("get", error)
    end
  end

  @impl true
  def get_by_google_id(google_id) do
    case execute(@user_id_by_google_id, [google_id], []) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [] -> :not_found
          [%{"user_id" => user_id}] -> get(user_id)
        end

      {:error, error} ->
        unavailable("get_by_google_id", error)
    end
  end

  @impl true
  def claim_google_id(google_id, user_id) do
    case execute(@claim, [google_id, user_id], serial_consistency: :serial) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [%{"[applied]" => true}] -> {:ok, user_id}
          [%{"[applied]" => false, "user_id" => winner_id}] -> {:ok, winner_id}
        end

      {:error, error} ->
        unavailable("claim_google_id", error)
    end
  end

  @impl true
  def put(%User{} = user) do
    params = [
      user.id,
      user.google_id,
      user.email,
      user.name,
      user.picture_url,
      user.email_verified,
      user.created_at,
      user.updated_at
    ]

    case execute(@put, params, []) do
      {:ok, _} -> :ok
      {:error, error} -> unavailable("put", error)
    end
  end

  defp one_user(page) do
    case Enum.to_list(page) do
      [] -> :not_found
      [row] -> {:ok, to_user(row)}
    end
  end

  # Logs the operation only: the keys are a user's Google identity, which does not belong in logs.
  defp unavailable(operation, error) do
    Logger.warning("UserStore.Cassandra #{operation} failed: #{error_message(error)}")
    {:error, :unavailable}
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp execute(statement, params, opts) do
    # ADR 0003: bound every call so a frozen or partitioned node yields 503, not a hang.
    timeout = Application.fetch_env!(:shortener_core, :cassandra_timeout)

    with {:ok, prepared} <- Xandra.prepare(Cassandra.conn(), statement, timeout: timeout) do
      Xandra.execute(Cassandra.conn(), prepared, params, [timeout: timeout] ++ opts)
    end
  end

  defp to_user(row) do
    %User{
      id: row["id"],
      google_id: row["google_id"],
      email: row["email"],
      name: row["name"],
      picture_url: row["picture_url"],
      email_verified: row["email_verified"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end
end
