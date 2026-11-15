defmodule WriteApi.Shortener do
  @moduledoc """
  Creates short links.

  The write is two steps (ADR 0004): claim the code with no TTL, then store the destination
  with a TTL. A crash between the steps leaves a claimed code with no destination; it returns
  410 and is never reused.
  """

  alias ShortenerCore.{Cache, KeySource, Url, UrlStore}
  alias WriteApi.LinkParams

  @type link :: %{code: String.t(), short_url: String.t(), expires_at: DateTime.t()}
  @type error :: LinkParams.error() | :alias_taken | :unavailable

  @doc """
  Creates a link from the body of `POST /urls`.

  Options: `:owner_id`, the `User.id` the link belongs to (default `nil`, an anonymous link),
  and `:now`, the creation time (default the current time).
  """
  @spec create(map(), keyword()) :: {:ok, link()} | {:error, error()}
  def create(params, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    owner_id = Keyword.get(opts, :owner_id)

    with {:ok, %{url: url, custom_alias: custom_alias, ttl_seconds: ttl}} <-
           LinkParams.parse(params) do
      expires_at = DateTime.add(now, ttl, :second)
      link = %{owner_id: owner_id, now: now, expires_at: expires_at}

      case custom_alias do
        nil -> create_generated(url, ttl, link)
        custom_alias -> create_custom(custom_alias, url, ttl, link)
      end
    end
  end

  defp create_custom(code, url, ttl, link) do
    case claim(code, true, link) do
      :ok -> finish(code, url, ttl, link.expires_at)
      {:error, :taken} -> {:error, :alias_taken}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # A generated key can clash with a custom alias (ADR 0001): discard it and take the next one.
  defp create_generated(url, ttl, link, attempt \\ 1) do
    with {:ok, code} <- KeySource.next_key() do
      case claim(code, false, link) do
        :ok ->
          finish(code, url, ttl, link.expires_at)

        {:error, :taken} ->
          if attempt < max_key_attempts() do
            create_generated(url, ttl, link, attempt + 1)
          else
            {:error, :unavailable}
          end

        {:error, :unavailable} ->
          {:error, :unavailable}
      end
    end
  end

  defp claim(code, is_custom_alias, %{owner_id: owner_id, now: now, expires_at: expires_at}) do
    UrlStore.claim(%Url{
      code: code,
      owner_id: owner_id,
      is_custom_alias: is_custom_alias,
      created_at: now,
      expires_at: expires_at
    })
  end

  defp finish(code, url, ttl, expires_at) do
    case UrlStore.put_destination(code, url, ttl) do
      :ok ->
        # Drop any negative entry cached before this code existed (ADR 0003). A cache error is
        # not fatal: the negative TTL is short.
        _ = Cache.delete(code)
        {:ok, %{code: code, short_url: base_url() <> "/" <> code, expires_at: expires_at}}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp max_key_attempts, do: Application.fetch_env!(:write_api, :max_key_attempts)
  defp base_url, do: Application.fetch_env!(:write_api, :base_url)
end
