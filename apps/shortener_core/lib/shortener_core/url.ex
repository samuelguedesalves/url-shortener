defmodule ShortenerCore.Url do
  @moduledoc """
  One row of the `urls` table.

  `long_url` is `nil` once the link has expired: only that column carries the TTL, the rest
  of the row is the permanent claim on the code (ADR 0004).
  """

  @enforce_keys [:code, :owner_id, :is_custom_alias, :created_at, :expires_at]
  defstruct [:code, :long_url, :owner_id, :is_custom_alias, :created_at, :expires_at]

  @type t :: %__MODULE__{
          code: String.t(),
          long_url: String.t() | nil,
          owner_id: String.t() | nil,
          is_custom_alias: boolean(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
