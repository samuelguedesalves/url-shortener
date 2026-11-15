defmodule WriteApi.DashboardCase do
  @moduledoc """
  Case template for the dashboard LiveView: starts the in-memory stores and provides
  `user!/2` and `signed_in_conn/2`. Not async, like the rest of the write_api tests.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, User, UrlStore, UserStore}
  alias WriteApi.Session

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import WriteApi.DashboardCase

      @endpoint WriteApi.Endpoint
    end
  end

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    start_supervised!(UserStore.Memory)
    :ok
  end

  @doc "Stores and returns a user with id `id`; `attrs` override the defaults."
  @spec user!(String.t(), map()) :: User.t()
  def user!(id, attrs \\ %{}) do
    now = ~U[2026-11-01 10:00:00.000Z]

    user =
      struct!(
        %User{
          id: id,
          google_id: "google-" <> id,
          email: id <> "@example.com",
          name: id,
          picture_url: nil,
          email_verified: true,
          created_at: now,
          updated_at: now
        },
        attrs
      )

    :ok = UserStore.put(user)
    user
  end

  @doc """
  A conn carrying a session cookie for `user_id`, issued exactly as `POST /auth/google` does.
  `opts[:now]` is forwarded to `WriteApi.Session.issue/3` as the issue time.
  """
  @spec signed_in_conn(String.t(), keyword()) :: Plug.Conn.t()
  def signed_in_conn(user_id, opts \\ []) do
    cookie = Session.issue(build_conn(), user_id, opts).resp_cookies["session"].value
    put_req_cookie(build_conn(), "session", cookie)
  end
end
