defmodule ShortenerCore.UrlStore do
  @moduledoc """
  Storage for short links. A link is written in two steps (ADR 0004):

    1. `claim/1` reserves the code permanently (no TTL).
    2. `put_destination/3` stores `long_url` with a TTL.

  `put_destination/3` must only be called after a successful `claim/1`: without a claim,
  Cassandra would create a row with no row marker that disappears at expiry and would make the
  code claimable again (ADR 0004).

  A link belongs to the user whose `User.id` is in `Url.owner_id` (`nil` for anonymous links).
  `claim/1` also adds an owned code to that owner's index, after the claim succeeded, so the
  index never lists a code someone else holds. `list_by_owner/3` reads the index. An index
  write that fails after the claim returns `{:error, :unavailable}` and burns the code, like
  any failure after the claim (ADR 0004).

  Implementation chosen by `config :shortener_core, :url_store`.
  """

  alias ShortenerCore.Url

  @callback claim(Url.t()) :: :ok | {:error, :taken | :unavailable}
  @callback put_destination(
              code :: String.t(),
              long_url :: String.t(),
              ttl_seconds :: pos_integer()
            ) ::
              :ok | {:error, :unavailable}
  @callback fetch(code :: String.t()) :: {:ok, Url.t()} | :not_found | {:error, :unavailable}
  @doc """
  The owner's links, newest first (`created_at` desc, then `code` asc), at most `limit`. An
  expired link has `long_url: nil`. `after` is the `{created_at, code}` of the last link of the
  previous page; only links strictly after it are returned.
  """
  @callback list_by_owner(
              owner_id :: String.t(),
              limit :: pos_integer(),
              after_cursor :: nil | {DateTime.t(), String.t()}
            ) :: {:ok, [Url.t()]} | {:error, :unavailable}

  def claim(%Url{} = url), do: impl().claim(url)
  def put_destination(code, long_url, ttl), do: impl().put_destination(code, long_url, ttl)
  def fetch(code), do: impl().fetch(code)
  def list_by_owner(owner_id, limit), do: impl().list_by_owner(owner_id, limit)

  def list_by_owner(owner_id, limit, after_cursor \\ nil),
    do: impl().list_by_owner(owner_id, limit, after_cursor)

  defp impl, do: Application.fetch_env!(:shortener_core, :url_store)
end
