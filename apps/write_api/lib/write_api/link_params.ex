defmodule WriteApi.LinkParams do
  @moduledoc """
  Validates and normalises the body of `POST /urls`.

  Body: `{"url": "https://...", "custom_alias": "my-link", "ttl_seconds": 3600}`.
  `custom_alias` and `ttl_seconds` are optional.
  """

  @max_url_length 2_048
  @alias_format ~r/\A[0-9A-Za-z_-]{3,32}\z/
  # Paths the services own, so an alias must not shadow them. Codes are permanent (ADR 0004),
  # so this also reserves names that later milestones may route.
  @reserved_aliases ~w(health urls stats metrics dashboard api admin static assets)
  # Whitespace and control characters: they would break, or inject into, the Location header.
  @forbidden_in_url ~r/[\x00-\x20\x7f]/

  @type t :: %{url: String.t(), custom_alias: String.t() | nil, ttl_seconds: pos_integer()}
  @type error :: :invalid_url | :invalid_alias | :invalid_ttl

  @spec parse(map()) :: {:ok, t()} | {:error, error()}
  def parse(params) when is_map(params) do
    with {:ok, url} <- parse_url(params["url"]),
         {:ok, custom_alias} <- parse_alias(params["custom_alias"]),
         {:ok, ttl} <- parse_ttl(params["ttl_seconds"]) do
      {:ok, %{url: url, custom_alias: custom_alias, ttl_seconds: ttl}}
    end
  end

  defp parse_url(url) when is_binary(url) and byte_size(url) <= @max_url_length do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         not Regex.match?(@forbidden_in_url, url) do
      {:ok, url}
    else
      {:error, :invalid_url}
    end
  end

  defp parse_url(_), do: {:error, :invalid_url}

  defp parse_alias(nil), do: {:ok, nil}

  defp parse_alias(custom_alias) when is_binary(custom_alias) do
    if Regex.match?(@alias_format, custom_alias) and
         String.downcase(custom_alias) not in @reserved_aliases do
      {:ok, custom_alias}
    else
      {:error, :invalid_alias}
    end
  end

  defp parse_alias(_), do: {:error, :invalid_alias}

  defp parse_ttl(nil), do: {:ok, Application.fetch_env!(:shortener_core, :default_link_ttl)}

  defp parse_ttl(ttl) when is_integer(ttl) do
    if ttl >= 1 and ttl <= Application.fetch_env!(:shortener_core, :max_link_ttl) do
      {:ok, ttl}
    else
      {:error, :invalid_ttl}
    end
  end

  defp parse_ttl(_), do: {:error, :invalid_ttl}
end
