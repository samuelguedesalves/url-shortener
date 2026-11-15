defmodule ShortenerCore.User do
  @moduledoc """
  One row of the `users` table: a person who signed in with Google.

  `id` is the application's own identifier and is what links (`Url.owner_id`) point at.
  `google_id` is the `sub` claim of the Google ID token, the only stable identity Google
  gives (the email can change). Never log in or match by email.
  """

  @enforce_keys [:id, :google_id, :email, :name, :email_verified, :created_at, :updated_at]
  defstruct [
    :id,
    :google_id,
    :email,
    :name,
    :picture_url,
    :email_verified,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          google_id: String.t(),
          email: String.t(),
          name: String.t(),
          picture_url: String.t() | nil,
          email_verified: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
