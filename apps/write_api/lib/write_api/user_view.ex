defmodule WriteApi.UserView do
  @moduledoc "The JSON shape of a signed-in user. Never includes `google_id`."

  alias ShortenerCore.User

  @spec to_map(User.t()) :: %{
          id: String.t(),
          email: String.t(),
          name: String.t(),
          picture_url: String.t() | nil
        }
  def to_map(%User{} = user) do
    %{id: user.id, email: user.email, name: user.name, picture_url: user.picture_url}
  end
end
