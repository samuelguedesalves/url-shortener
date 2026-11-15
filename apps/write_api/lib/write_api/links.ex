defmodule WriteApi.Links do
  @moduledoc "Lists a user's links, newest first, one cursor-paginated page at a time."

  alias ShortenerCore.UrlStore
  alias WriteApi.{Cursor, LinkView}

  @default_limit 20
  @max_limit 100

  @type page :: %{links: [map()], next_cursor: String.t() | nil}

  @doc """
  `query` is the raw string-keyed query map (`"limit"`, `"cursor"`). The store is asked for one
  link more than `limit` to learn whether a next page exists.
  """
  @spec page(String.t(), map()) ::
          {:ok, page()} | {:error, :invalid_limit | :invalid_cursor | :unavailable}
  def page(owner_id, query) do
    with {:ok, limit} <- parse_limit(Map.get(query, "limit")),
         {:ok, after_cursor} <- parse_cursor(Map.get(query, "cursor")),
         {:ok, urls} <- UrlStore.list_by_owner(owner_id, limit + 1, after_cursor) do
      {shown, rest} = Enum.split(urls, limit)
      now = DateTime.utc_now()

      {:ok,
       %{links: Enum.map(shown, &LinkView.to_map(&1, now)), next_cursor: next_cursor(shown, rest)}}
    end
  end

  defp next_cursor(_shown, []), do: nil

  defp next_cursor(shown, _rest) do
    last = List.last(shown)
    Cursor.encode(last.created_at, last.code)
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(raw) when is_binary(raw) do
    with true <- Regex.match?(~r/\A\d+\z/, raw),
         {limit, ""} when limit >= 1 and limit <= @max_limit <- Integer.parse(raw) do
      {:ok, limit}
    else
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_raw), do: {:error, :invalid_limit}

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(raw) do
    case Cursor.decode(raw) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> {:error, :invalid_cursor}
    end
  end
end
