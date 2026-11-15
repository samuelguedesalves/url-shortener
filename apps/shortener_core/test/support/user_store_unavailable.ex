defmodule ShortenerCore.UserStore.Unavailable do
  @moduledoc """
  `UserStore` double whose every call fails, to test how callers handle a Cassandra outage.
  Select it with `Application.put_env(:shortener_core, :user_store, ShortenerCore.UserStore.Unavailable)`.
  """

  @behaviour ShortenerCore.UserStore

  @impl true
  def get(_id), do: {:error, :unavailable}

  @impl true
  def get_by_google_id(_google_id), do: {:error, :unavailable}

  @impl true
  def claim_google_id(_google_id, _user_id), do: {:error, :unavailable}

  @impl true
  def put(_user), do: {:error, :unavailable}
end
