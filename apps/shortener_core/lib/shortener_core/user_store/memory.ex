defmodule ShortenerCore.UserStore.Memory do
  @moduledoc """
  In-memory `UserStore` for unit tests. Start it with
  `start_supervised!(ShortenerCore.UserStore.Memory)`.
  """

  @behaviour ShortenerCore.UserStore

  use Agent

  alias ShortenerCore.User

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{users: %{}, google_ids: %{}} end, name: __MODULE__)
  end

  @impl true
  def get(id) do
    Agent.get(__MODULE__, fn %{users: users} -> fetch(users, id) end)
  end

  @impl true
  def get_by_google_id(google_id) do
    Agent.get(__MODULE__, fn %{users: users, google_ids: google_ids} ->
      case Map.fetch(google_ids, google_id) do
        {:ok, user_id} -> fetch(users, user_id)
        :error -> :not_found
      end
    end)
  end

  @impl true
  def claim_google_id(google_id, user_id) do
    Agent.get_and_update(__MODULE__, fn %{google_ids: google_ids} = state ->
      case Map.fetch(google_ids, google_id) do
        {:ok, winner_id} -> {{:ok, winner_id}, state}
        :error -> {{:ok, user_id}, %{state | google_ids: Map.put(google_ids, google_id, user_id)}}
      end
    end)
  end

  @impl true
  def put(%User{} = user) do
    Agent.update(__MODULE__, fn %{users: users} = state ->
      %{state | users: Map.put(users, user.id, user)}
    end)
  end

  defp fetch(users, id) do
    case Map.fetch(users, id) do
      {:ok, user} -> {:ok, user}
      :error -> :not_found
    end
  end
end
