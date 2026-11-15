defmodule ShortenerCore.UserStore do
  @moduledoc """
  Storage for users. Cassandra has no transaction across tables, so a user lives in two:
  `users` (by internal id) and `users_by_google_id` (Google `sub` to internal id).

  A user is written in two steps, in this order:

    1. `claim_google_id/2` reserves the Google `sub` for an internal id, atomically. If the
       `sub` is already claimed it returns the id that holds it. Concurrent first logins all
       agree on one id.
    2. `put/1` writes the `users` row.

  A crash between the steps leaves a claim with no `users` row. `get_by_google_id/1` reports
  that as `:not_found`, and the next login finishes the registration with the claimed id
  (see `ShortenerCore.Users`).

  Implementation chosen by `config :shortener_core, :user_store`.
  """

  alias ShortenerCore.User

  @callback get(id :: String.t()) :: {:ok, User.t()} | :not_found | {:error, :unavailable}
  @callback get_by_google_id(google_id :: String.t()) ::
              {:ok, User.t()} | :not_found | {:error, :unavailable}
  @callback claim_google_id(google_id :: String.t(), user_id :: String.t()) ::
              {:ok, winner_id :: String.t()} | {:error, :unavailable}
  @callback put(User.t()) :: :ok | {:error, :unavailable}

  def get(id), do: impl().get(id)
  def get_by_google_id(google_id), do: impl().get_by_google_id(google_id)
  def claim_google_id(google_id, user_id), do: impl().claim_google_id(google_id, user_id)
  def put(%User{} = user), do: impl().put(user)

  defp impl, do: Application.fetch_env!(:shortener_core, :user_store)
end
